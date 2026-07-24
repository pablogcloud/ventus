import AppKit
import SwiftUI

struct PopoverView: View {
    @ObservedObject var observer: DaemonClientObserver
    @Binding var showMainWindow: Bool
    // One-time authorization: once granted, profile switches arm/drive the
    // fans directly with no per-action confirmation.
    @AppStorage("controlAuthorized") private var controlAuthorized = false
    @State private var pendingProfile: String?
    @State private var actionTask: Task<Void, Never>?
    @State private var actionGeneration = 0
    @State private var actionError: String?
    @Environment(\.openWindow) private var openWindow

    // Same token gate as AppDelegate's debug observer: the command must carry
    // the secret from ~/.ventus-debug, re-validated per event.
    private static let debugTokenPath = NSString(string: "~/.ventus-debug").expandingTildeInPath
    private static let debugToken: String? = {
        guard let token = try? String(contentsOfFile: debugTokenPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty else { return nil }
        return token
    }()

    var body: some View {
        Group {
            if let status = observer.status {
                connectedContent(status)
            } else {
                unreachableContent
            }
        }
        .padding(15)
        .frame(width: 330)
        .foregroundStyle(VentusPalette.ink)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .ventusGlass(radius: 16)
        .onChange(of: observer.status?.isFanControlAvailable ?? true) { _, isAvailable in
            if !isAvailable {
                pendingProfile = nil
            }
        }
        .onReceive(
            DistributedNotificationCenter.default()
                .publisher(for: Notification.Name("com.formm.ventus.debug.command"))
        ) { note in
            guard let token = Self.debugToken,
                  note.object as? String == "\(token):openMain",
                  (try? String(contentsOfFile: Self.debugTokenPath, encoding: .utf8))?
                      .trimmingCharacters(in: .whitespacesAndNewlines) == token
            else { return }
            openMainWindow()
        }
    }

    private func connectedContent(_ status: TelemetrySnapshot) -> some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Ventus")
                    .font(VentusFont.display(15, weight: .bold))
                    .foregroundStyle(VentusPalette.ink)
                Spacer()
                Text(headerMeta(status))
                    .font(VentusFont.body(12))
                    .foregroundStyle(VentusPalette.ink2)
            }

            profileSelector(status)

            if status.isFanControlAvailable || !status.fans.isEmpty {
                fanCards(status)
            }

            ReasonPill(text: reasonText(status))

            if status.isFanControlAvailable {
                armControls(status)
            } else {
                Text("Monitor-only · no fans on this Mac")
                    .font(VentusFont.body(11, weight: .medium))
                    .foregroundStyle(VentusPalette.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                openMainWindow()
            } label: {
                HStack {
                    Text("Open Ventus…")
                    Spacer()
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 10, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(VentusButtonStyle(kind: .secondary))
        }
    }

    private var unreachableContent: some View {
        VentusUnavailableState(
            title: "Daemon Unreachable",
            message: observer.errorMessage
                ?? "The Ventus daemon is not responding. Fans remain on Apple auto.",
            buttonTitle: "Open Ventus",
            action: openMainWindow
        )
        .frame(maxWidth: .infinity)
    }

    private func profileSelector(_ status: TelemetrySnapshot) -> some View {
        HStack(spacing: 4) {
            profileButton(key: "quiet", title: "Quiet", status: status)
            profileButton(key: "balanced", title: "Balanced", status: status)
            profileButton(key: "performance", title: "Perf", status: status)
            profileButton(key: "auto-apple", title: "Auto", status: status)
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
        }
    }

    private func profileButton(
        key: String,
        title: String,
        status: TelemetrySnapshot
    ) -> some View {
        VentusSegmentButton(
            title: title,
            isSelected: key == "auto-apple"
                ? status.mode != "armed"
                : status.mode == "armed" && status.activeProfile == key,
            isEnabled: status.isFanControlAvailable,
            action: { select(profile: key) }
        )
    }

    private func select(profile key: String) {
        if key == "auto-apple" {
            pendingProfile = nil
            enqueueAction { gen in
                let ok = await observer.disarm()
                guard gen == actionGeneration else { return }
                actionError = ok ? nil : "Couldn't verify fans back to Apple auto — check the daemon log."
            }
        } else if !controlAuthorized {
            // No animation: animated height changes feed preferredContentSize →
            // window resize → constraint re-layout in a loop until the stack
            // overflows (reproduced by clicking Perf unauthorized).
            pendingProfile = key
        } else {
            pendingProfile = nil
            enqueueAction { gen in await activate(key, generation: gen) }
        }
    }

    /// Runs one control transaction strictly AFTER any in-flight one finishes
    /// (Task.cancel cannot retract an XPC call that's already been sent, so
    /// ordering — not cancellation — is what prevents a stale arm from landing
    /// after a later disarm). The generation token makes superseded
    /// transactions no-op at every step boundary.
    private func enqueueAction(_ body: @escaping (Int) async -> Void) {
        actionGeneration += 1
        let gen = actionGeneration
        // actionError is NOT cleared here: a failed-restore warning stays valid
        // until the new transaction reports its own outcome (which overwrites
        // or clears it, generation-guarded). controlCall guarantees every
        // transaction resolves, so the warning can't linger forever.
        let previous = actionTask
        actionTask = Task {
            _ = await previous?.value
            guard gen == actionGeneration else { return }
            await body(gen)
        }
    }

    /// Switch to a control profile; arms afterwards if the daemon is observing.
    /// Never arms when the profile switch itself was rejected.
    private func activate(_ key: String, generation gen: Int) async {
        guard gen == actionGeneration else { return }
        guard await observer.setProfile(key) else {
            guard gen == actionGeneration else { return }
            actionError = "The daemon rejected the \(ventusProfileTitle(key)) profile."
            return
        }
        guard gen == actionGeneration else { return }
        if observer.status?.mode != "armed" {
            let ok = await observer.arm()
            guard gen == actionGeneration else { return }
            actionError = ok ? nil : "Couldn't enable fan control — check the daemon log."
        } else {
            actionError = nil
        }
    }

    @ViewBuilder
    private func fanCards(_ status: TelemetrySnapshot) -> some View {
        if status.fans.isEmpty {
            Text("Fan telemetry is not available yet.")
                .font(VentusFont.body(11))
                .foregroundStyle(VentusPalette.ink3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial)
                }
        } else {
            HStack(spacing: 8) {
                ForEach(status.fans.prefix(2), id: \.fanIndex) { fan in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ventusFanLabel(index: fan.fanIndex).uppercased())
                            .font(VentusFont.body(10, weight: .semibold))
                            .foregroundStyle(VentusPalette.accentDeep)
                            .lineLimit(1)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(String(format: "%.0f", fan.actualRPM))
                                .font(VentusFont.number(19, weight: .bold))
                                .foregroundStyle(VentusPalette.ink)
                            Text("rpm")
                                .font(VentusFont.body(10, weight: .medium))
                                .foregroundStyle(VentusPalette.ink3)
                        }
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.ultraThinMaterial)
                    }
                }
            }
        }
    }

    private func armControls(_ status: TelemetrySnapshot) -> some View {
        // Authorize-once model: the profile selector IS the control surface.
        // Picking Quiet/Balanced/Perf arms and drives; Auto returns to Apple.
        // The first-ever pick shows a single authorization card, then never again.
        VStack(spacing: 9) {
            if let actionError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(actionError)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(VentusFont.body(10, weight: .medium))
                .foregroundStyle(VentusPalette.warn)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let pending = pendingProfile {
                authorizationCard(pending)
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fan control")
                            .font(VentusFont.body(12, weight: .semibold))
                            .foregroundStyle(VentusPalette.ink)
                        Text(
                            status.mode == "armed"
                                ? "Ventus is driving your fans"
                                : "Apple auto — pick a profile to take control"
                        )
                        .font(VentusFont.body(10))
                        .foregroundStyle(status.mode == "armed" ? VentusPalette.accentDeep : VentusPalette.ink3)
                    }
                    Spacer()
                    if status.mode == "armed" {
                        Circle()
                            .fill(VentusPalette.accent)
                            .frame(width: 8, height: 8)
                    }
                }
            }
        }
    }

    private func authorizationCard(_ pending: String) -> some View {
        VStack(spacing: 8) {
            Text("Enable fan control?")
                .font(VentusFont.body(12, weight: .semibold))
                .foregroundStyle(VentusPalette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Ventus will drive the fans with your curves. Any error, crash, or thermal limit instantly returns them to Apple auto. You won't be asked again.")
                .font(VentusFont.body(11))
                .foregroundStyle(VentusPalette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button {
                    pendingProfile = nil
                } label: {
                    Text("Not now").frame(maxWidth: .infinity)
                }
                .buttonStyle(VentusButtonStyle(kind: .ghost))
                Button {
                    controlAuthorized = true
                    pendingProfile = nil
                    enqueueAction { gen in await activate(pending, generation: gen) }
                } label: {
                    Text("Enable").frame(maxWidth: .infinity)
                }
                .buttonStyle(VentusButtonStyle(kind: .primary))
            }
        }
        .padding(10)
        .background(VentusPalette.accentTint)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func headerMeta(_ status: TelemetrySnapshot) -> String {
        let temperature = status.temperature(for: "cpu_perf") ?? status.hottestTemperature
        let temperatureText = temperature.map { String(format: "CPU %.0f°C", $0) } ?? "CPU --°C"
        let powerText = status.packageWatts.map { String(format: "%.0f W", $0) } ?? "-- W"
        return "\(temperatureText) · \(powerText)"
    }

    private func reasonText(_ status: TelemetrySnapshot) -> String {
        guard status.mode == "armed" else {
            // Don't claim Apple has the fans while the last transaction failed
            // (e.g. a disarm whose restore could not be verified).
            if actionError != nil {
                return "Fan state unverified — see the warning below"
            }
            return "Apple is managing the fans"
        }
        guard let explanation = status.explanations.first else {
            if let rule = status.activeRule, !rule.isEmpty {
                return rule
            }
            return "\(ventusProfileTitle(status.activeProfile)) profile is active"
        }

        switch explanation.winner {
        case "safety_override":
            return "Thermal safety is setting the fan target"
        case "pressure_floor":
            return "System pressure is holding a safe fan floor"
        case "slew_limited":
            return "Fan speed is changing gradually"
        case "power_curve":
            return "Package power is leading the fan target"
        default:
            return "Temperature curve is setting the fan target"
        }
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        showMainWindow = true
        openWindow(id: "mainWindow")
    }
}

private struct ReasonPill: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 30)) { timeline in
            let pulse = reduceMotion
                ? 1
                : 0.58 + (sin(timeline.date.timeIntervalSinceReferenceDate * 2.8) + 1) * 0.21
            HStack(spacing: 8) {
                Circle()
                    .fill(VentusPalette.accent)
                    .frame(width: 7, height: 7)
                    .opacity(pulse)
                Text(text)
                    .font(VentusFont.body(11, weight: .medium))
                    .foregroundStyle(VentusPalette.accentDeep)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(VentusPalette.accentTint)
            }
        }
    }
}
