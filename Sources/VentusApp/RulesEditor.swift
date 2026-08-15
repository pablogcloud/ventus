import SwiftUI
import VentusCore

/// Editable list of auto-switch rules.
///
/// Priority is derived from list order — top row wins — rather than exposed as a
/// number. Two rules could otherwise be given the same priority, which both
/// makes the outcome ambiguous and (in the previous read-only list, which keyed
/// `ForEach` on priority) silently collapsed rows.
struct RulesEditor: View {
    let config: Config
    @ObservedObject var observer: DaemonClientObserver

    @State private var rows: [EditableRule] = []
    @State private var threshold: String = ""
    @State private var loadedFrom: [Rule] = []
    @State private var saveError: String?

    private var profileNames: [String] { config.profiles.keys.sorted() }
    private var chipDefault: Double { ChipInfo.current.defaultGameGPUWatts }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VentusSectionHeader(
                title: "Rules",
                detail: rows.isEmpty ? "none" : "\(rows.count) · top match wins"
            )

            if rows.isEmpty {
                Text("No rules yet. Ventus will stay on Balanced unless you pick a profile yourself.")
                    .font(VentusFont.body(12))
                    .foregroundStyle(VentusPalette.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(VentusPalette.lift)
                    }
            } else {
                ForEach($rows) { $row in
                    RuleRow(
                        row: $row,
                        profileNames: profileNames,
                        isFirst: rows.first?.id == row.id,
                        isLast: rows.last?.id == row.id,
                        onMoveUp: { move(row.id, by: -1) },
                        onMoveDown: { move(row.id, by: 1) },
                        onDelete: { delete(row.id) }
                    )
                }
                .onChange(of: rows) { _, _ in save() }
            }

            if rows.contains(where: { $0.kind == .gameDetected }) {
                gameThresholdField
            }

            HStack(spacing: 10) {
                Button {
                    rows.append(EditableRule(profileName: defaultProfile))
                } label: {
                    Label("Add rule", systemImage: "plus")
                }
                .buttonStyle(VentusButtonStyle(kind: .ghost))

                if let saveError {
                    Text(saveError)
                        .font(VentusFont.body(11, weight: .medium))
                        .foregroundStyle(VentusPalette.hot)
                }
                Spacer()
            }
        }
        .ventusCard()
        .onAppear(perform: load)
        .onChange(of: config.rules.rules) { _, _ in load() }
    }

    private var gameThresholdField: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(VentusPalette.ink3)
            Text("Count as a game above")
                .font(VentusFont.body(11))
                .foregroundStyle(VentusPalette.ink2)
            TextField("\(Int(chipDefault))", text: $threshold)
                .textFieldStyle(.roundedBorder)
                .frame(width: 62)
                .onSubmit(save)
            Text("W GPU")
                .font(VentusFont.body(11))
                .foregroundStyle(VentusPalette.ink2)
            Spacer()
            // The number is meaningless without knowing the GPU's size, so name
            // the chip it was derived from.
            Text("\(Int(chipDefault)) W suits your \(ChipInfo.current.name)")
                .font(VentusFont.body(10))
                .foregroundStyle(VentusPalette.ink3)
        }
        .padding(.top, 2)
    }

    private var defaultProfile: String {
        profileNames.contains("balanced") ? "balanced" : (profileNames.first ?? "balanced")
    }

    // MARK: - Load / save

    private func load() {
        let sorted = config.rules.rules.sorted { $0.priority > $1.priority }
        guard sorted != loadedFrom else { return }
        loadedFrom = sorted
        rows = sorted.map(EditableRule.init)
        threshold = config.rules.gameGPUWattsThreshold.map { String(Int($0)) } ?? ""
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard rows.indices.contains(target) else { return }
        rows.swapAt(index, target)
    }

    private func delete(_ id: UUID) {
        rows.removeAll { $0.id == id }
        save()
    }

    private func save() {
        var updated = config
        // Descending, spaced, so list order alone determines who wins.
        updated.rules.rules = rows.enumerated().map { index, row in
            row.rule(priority: (rows.count - index) * 10)
        }
        updated.rules.gameGPUWattsThreshold = Double(threshold.trimmingCharacters(in: .whitespaces))

        do {
            try updated.validate()
        } catch {
            saveError = "\(error)"
            return
        }

        Task {
            let ok = await observer.setConfig(updated)
            if ok {
                observer.updateConfig(updated)
                loadedFrom = updated.rules.rules.sorted { $0.priority > $1.priority }
                saveError = nil
            } else {
                saveError = "The daemon rejected this change."
            }
        }
    }
}

// MARK: - One row

private struct RuleRow: View {
    @Binding var row: EditableRule
    let profileNames: [String]
    let isFirst: Bool
    let isLast: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 1) {
                orderButton("chevron.up", disabled: isFirst, action: onMoveUp)
                orderButton("chevron.down", disabled: isLast, action: onMoveDown)
            }

            Image(systemName: row.kind.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VentusPalette.accent)
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(VentusPalette.accentTint)
                }

            Picker("", selection: $row.kind) {
                ForEach(TriggerKind.allCases, id: \.self) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 176)

            parameterField

            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(VentusPalette.ink3)

            Picker("", selection: $row.profileName) {
                ForEach(profileNames, id: \.self) { name in
                    Text(ventusProfileTitle(name)).tag(name)
                }
            }
            .labelsHidden()
            .frame(width: 122)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(VentusPalette.ink3)
            }
            .buttonStyle(.plain)
            .help("Remove this rule")
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(VentusPalette.surface2.opacity(0.72))
        }
    }

    @ViewBuilder
    private var parameterField: some View {
        switch row.kind {
        case .appRunning:
            TextField("com.example.app", text: $row.bundleID)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 150)
        case .timeWindow:
            HStack(spacing: 4) {
                hourPicker($row.startHour)
                Text("–")
                    .font(VentusFont.body(11))
                    .foregroundStyle(VentusPalette.ink3)
                hourPicker($row.endHour)
            }
        default:
            Spacer(minLength: 0)
        }
    }

    private func hourPicker(_ hour: Binding<Int>) -> some View {
        Picker("", selection: hour) {
            ForEach(0 ..< 24, id: \.self) { h in
                Text(String(format: "%02d:00", h)).tag(h)
            }
        }
        .labelsHidden()
        .frame(width: 78)
    }

    private func orderButton(
        _ symbol: String, disabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(disabled ? VentusPalette.ink3.opacity(0.35) : VentusPalette.ink2)
                .frame(width: 16, height: 12)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

// MARK: - Editing model

/// SwiftUI needs a stable identity and mutable fields to bind to; `Rule` has
/// neither (all-`let`, no id). This carries every trigger's parameters at once
/// so switching kind back and forth does not lose what you typed.
struct EditableRule: Identifiable, Equatable {
    let id = UUID()
    var kind: TriggerKind = .gameDetected
    var bundleID: String = ""
    var startHour: Int = 22
    var endHour: Int = 7
    var profileName: String

    init(profileName: String) {
        self.profileName = profileName
    }

    init(_ rule: Rule) {
        profileName = rule.profileName
        switch rule.trigger {
        case .onBattery: kind = .onBattery
        case .onAC: kind = .onAC
        case .clamshellClosed: kind = .clamshellClosed
        case .externalDisplayConnected: kind = .externalDisplayConnected
        case .gameDetected: kind = .gameDetected
        case .appRunning(let bundleId):
            kind = .appRunning
            bundleID = bundleId
        case .timeWindow(let start, let end):
            kind = .timeWindow
            startHour = start
            endHour = end
        }
    }

    func rule(priority: Int) -> Rule {
        let trigger: RuleTrigger
        switch kind {
        case .onBattery: trigger = .onBattery
        case .onAC: trigger = .onAC
        case .clamshellClosed: trigger = .clamshellClosed
        case .externalDisplayConnected: trigger = .externalDisplayConnected
        case .gameDetected: trigger = .gameDetected
        case .appRunning: trigger = .appRunning(bundleId: bundleID)
        case .timeWindow: trigger = .timeWindow(startHour: startHour, endHour: endHour)
        }
        return Rule(priority: priority, trigger: trigger, profileName: profileName)
    }
}

enum TriggerKind: String, CaseIterable {
    case gameDetected, appRunning, timeWindow
    case onBattery, onAC, clamshellClosed, externalDisplayConnected

    var label: String {
        switch self {
        case .gameDetected:             return "A game is running"
        case .appRunning:               return "An app is running"
        case .timeWindow:               return "Between these hours"
        case .onBattery:                return "On battery"
        case .onAC:                     return "On AC power"
        case .clamshellClosed:          return "Lid closed"
        case .externalDisplayConnected: return "External display"
        }
    }

    var icon: String {
        switch self {
        case .gameDetected:             return "gamecontroller.fill"
        case .appRunning:               return "app.fill"
        case .timeWindow:               return "clock.fill"
        case .onBattery:                return "battery.50percent"
        case .onAC:                     return "powerplug.fill"
        case .clamshellClosed:          return "macbook"
        case .externalDisplayConnected: return "display"
        }
    }
}
