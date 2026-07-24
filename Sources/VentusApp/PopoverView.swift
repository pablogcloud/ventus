import AppKit
import SwiftUI

struct PopoverView: View {
    @ObservedObject var observer: DaemonClientObserver
    @Binding var showMainWindow: Bool
    @State private var showArmConfirmation = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let status = observer.status {
                connectedContent(status)
            } else {
                unreachableContent
            }
        }
        .padding(15)
        .frame(width: 316)
        .background(.ultraThinMaterial)
        .background(VentusPalette.surface.opacity(0.82))
        .foregroundStyle(VentusPalette.ink)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(VentusPalette.border, lineWidth: 1)
        }
        .onChange(of: observer.status?.isFanControlAvailable ?? true) { _, isAvailable in
            if !isAvailable {
                showArmConfirmation = false
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
            isSelected: status.activeProfile == key,
            isEnabled: status.isFanControlAvailable,
            action: {
                Task {
                    if key == "auto-apple" {
                        _ = await observer.setAppleAuto()
                    } else {
                        _ = await observer.setProfile(key)
                    }
                }
            }
        )
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
        VStack(spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fan control")
                        .font(VentusFont.body(12, weight: .semibold))
                        .foregroundStyle(VentusPalette.ink)
                    Text(status.mode == "armed" ? "Armed" : "Apple auto")
                        .font(VentusFont.body(10))
                        .foregroundStyle(VentusPalette.ink3)
                }
                Spacer()
                // A plain Toggle here triggers a modal alert, which a MenuBarExtra
                // popover dismisses on focus loss. Use a button that reveals an
                // INLINE confirmation inside the popover instead — no separate window.
                Toggle(
                    "",
                    isOn: Binding(
                        get: { status.mode == "armed" || showArmConfirmation },
                        set: { shouldArm in
                            if shouldArm {
                                showArmConfirmation = true
                            } else if status.mode == "armed" {
                                Task { _ = await observer.disarm() }
                            } else {
                                showArmConfirmation = false
                            }
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(VentusPalette.accent)
            }

            if showArmConfirmation && status.mode != "armed" {
                // Inline confirmation — stays within the popover window.
                VStack(spacing: 8) {
                    Text("Arm fan control? Fans will follow your curves. Any error or crash reverts to Apple auto.")
                        .font(VentusFont.body(11))
                        .foregroundStyle(VentusPalette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        Button {
                            showArmConfirmation = false
                        } label: {
                            Text("Cancel").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(VentusButtonStyle(kind: .ghost))
                        Button {
                            showArmConfirmation = false
                            Task { _ = await observer.arm() }
                        } label: {
                            Text("Arm").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(VentusButtonStyle(kind: .primary))
                    }
                }
                .padding(10)
                .background(VentusPalette.accentTint)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if status.mode == "armed" {
                Button {
                    Task { _ = await observer.setAppleAuto() }
                } label: {
                    Text("Return to Apple auto")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VentusButtonStyle(kind: .ghost))
            }
        }
    }

    private func headerMeta(_ status: TelemetrySnapshot) -> String {
        let temperature = status.temperature(for: "cpu_perf") ?? status.hottestTemperature
        let temperatureText = temperature.map { String(format: "CPU %.0f°C", $0) } ?? "CPU --°C"
        let powerText = status.packageWatts.map { String(format: "%.0f W", $0) } ?? "-- W"
        return "\(temperatureText) · \(powerText)"
    }

    private func reasonText(_ status: TelemetrySnapshot) -> String {
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
