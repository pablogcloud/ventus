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
    @State private var actionError: String?
    @Environment(\.openWindow) private var openWindow

    private static let debugEnabled = FileManager.default.fileExists(
        atPath: NSString(string: "~/.ventus-debug").expandingTildeInPath
    )

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
        .background(VentusPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(VentusPalette.border, lineWidth: 1)
        }
        .onChange(of: observer.status?.isFanControlAvailable ?? true) { _, isAvailable in
            if !isAvailable {
                pendingProfile = nil
            }
        }
        .onReceive(
            DistributedNotificationCenter.default()
                .publisher(for: Notification.Name("com.formm.ventus.debug.command"))
        ) { note in
            if Self.debugEnabled, note.object as? String == "openMain" {
                openMainWindow()
            }
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
                .fill(VentusPalette.surface2)
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
        // One in-flight control transaction at a time: a stale setProfile→arm
        // must never land after a later Auto/disarm click.
        actionTask?.cancel()
        if key == "auto-apple" {
            pendingProfile = nil
            actionTask = Task {
                let ok = await observer.disarm()
                guard !Task.isCancelled else { return }
                actionError = ok ? nil : "Couldn't verify fans back to Apple auto — check the daemon log."
            }
        } else if !controlAuthorized {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                pendingProfile = key
            }
        } else {
            pendingProfile = nil
            actionTask = Task { await activate(key) }
        }
    }

    /// Switch to a control profile; arms afterwards if the daemon is observing.
    /// Never arms when the profile switch itself was rejected.
    private func activate(_ key: String) async {
        guard await observer.setProfile(key) else {
            guard !Task.isCancelled else { return }
            actionError = "The daemon rejected the \(ventusProfileTitle(key)) profile."
            return
        }
        guard !Task.isCancelled else { return }
        if observer.status?.mode != "armed" {
            let ok = await observer.arm()
            guard !Task.isCancelled else { return }
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
                        .fill(VentusPalette.surface2)
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
                            .fill(VentusPalette.surface2)
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
                    withAnimation { pendingProfile = nil }
                } label: {
                    Text("Not now").frame(maxWidth: .infinity)
                }
                .buttonStyle(VentusButtonStyle(kind: .ghost))
                Button {
                    controlAuthorized = true
                    pendingProfile = nil
                    actionTask?.cancel()
                    actionTask = Task { await activate(pending) }
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
