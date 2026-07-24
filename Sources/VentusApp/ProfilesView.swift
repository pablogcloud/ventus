import SwiftUI
import VentusCore

struct ProfilesTabView: View {
    @ObservedObject var observer: DaemonClientObserver
    @State private var selectedProfile = "balanced"
    @State private var applyingProfile: String?
    @State private var feedback: String?

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]

    var body: some View {
        ScrollView {
            Group {
                if let config = observer.config {
                    profiles(config)
                } else {
                    loadingState
                }
            }
            .padding(20)
        }
        .background(Color.clear)
        .onAppear(perform: syncSelection)
        .onChange(of: observer.status?.activeProfile) { _, _ in
            syncSelection()
        }
    }

    private func profiles(_ config: Config) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Profiles")
                        .font(VentusFont.display(20, weight: .bold))
                        .foregroundStyle(VentusPalette.ink)
                    Text("Choose how Ventus balances noise and cooling.")
                        .font(VentusFont.body(12))
                        .foregroundStyle(VentusPalette.ink2)
                }
                Spacer()
                if let feedback {
                    Text(feedback)
                        .font(VentusFont.body(11, weight: .medium))
                        .foregroundStyle(VentusPalette.hot)
                }
            }

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(config.profiles.keys.sorted(by: profileOrder), id: \.self) { name in
                    if let profile = config.profiles[name] {
                        ProfileCard(
                            name: name,
                            profile: profile,
                            isSelected: selectedProfile == name,
                            isApplying: applyingProfile == name,
                            action: { activateProfile(name) }
                        )
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                VentusSectionHeader(
                    title: "Rules",
                    detail: "\(config.rules.rules.count) configured"
                )

                if config.rules.rules.isEmpty {
                    Text("No automatic profile rules are configured.")
                        .font(VentusFont.body(12))
                        .foregroundStyle(VentusPalette.ink3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(.ultraThinMaterial)
                        }
                } else {
                    ForEach(
                        config.rules.rules.sorted { $0.priority > $1.priority },
                        id: \.priority
                    ) { rule in
                        RuleCard(rule: rule)
                    }
                }
            }
            .ventusCard()
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .tint(VentusPalette.accent)
            Text("Loading profiles")
                .font(VentusFont.display(15, weight: .semibold))
                .foregroundStyle(VentusPalette.ink)
            Text("Waiting for the daemon configuration.")
                .font(VentusFont.body(12))
                .foregroundStyle(VentusPalette.ink2)
        }
        .frame(maxWidth: .infinity, minHeight: 430)
    }

    private func syncSelection() {
        if let active = observer.status?.activeProfile {
            selectedProfile = active
        } else if let pinned = observer.config?.pinnedProfile {
            selectedProfile = pinned
        }
    }

    private func activateProfile(_ name: String) {
        applyingProfile = name
        feedback = nil
        Task {
            let success = await observer.setProfile(name)
            if success {
                selectedProfile = name
            } else {
                feedback = "The daemon could not activate this profile."
            }
            applyingProfile = nil
        }
    }

    private func profileOrder(_ left: String, _ right: String) -> Bool {
        let order = ["quiet", "balanced", "performance", "auto-apple"]
        return (order.firstIndex(of: left) ?? order.count)
            < (order.firstIndex(of: right) ?? order.count)
    }
}

private struct ProfileCard: View {
    let name: String
    let profile: Profile
    let isSelected: Bool
    let isApplying: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ventusProfileTitle(name))
                        .font(VentusFont.display(16, weight: .bold))
                        .foregroundStyle(VentusPalette.ink)
                    Text(profileSubtitle)
                        .font(VentusFont.body(11))
                        .foregroundStyle(VentusPalette.ink2)
                }
                Spacer()
                if isApplying {
                    ProgressView()
                        .controlSize(.small)
                        .tint(VentusPalette.accent)
                } else if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(VentusPalette.onAccent)
                        .frame(width: 24, height: 24)
                        .background {
                            Circle()
                                .fill(VentusPalette.accent)
                        }
                }
            }

            HStack(spacing: 8) {
                ProfileMetric(value: "\(profile.curves.count)", label: "fans")
                ProfileMetric(
                    value: String(format: "%.0f°C", profile.hysteresisGapC),
                    label: "gap"
                )
                ProfileMetric(
                    value: String(format: "%.0fs", profile.emaTimeConstantS),
                    label: "smoothing"
                )
            }

            Button(action: action) {
                HStack(spacing: 7) {
                    if isApplying {
                        ProgressView()
                            .controlSize(.small)
                            .tint(VentusPalette.onAccent)
                    }
                    Text(isSelected ? "Active" : "Activate")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(VentusButtonStyle(kind: .primary))
            .disabled(isSelected || isApplying)
            .opacity(isSelected ? 0.68 : 1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .leading)
        .ventusGlass(radius: 18)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    isSelected ? VentusPalette.accent : VentusPalette.border,
                    lineWidth: isSelected ? 1.5 : 1
                )
        }
        .scaleEffect(isHovering ? 1.008 : 1)
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var profileSubtitle: String {
        switch name {
        case "quiet":
            return "Lower fan speeds for quiet work"
        case "balanced":
            return "Everyday thermal balance"
        case "performance":
            return "Earlier, stronger cooling"
        case "auto-apple":
            return "Return control to macOS"
        default:
            return "Custom thermal profile"
        }
    }
}

private struct ProfileMetric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(VentusFont.number(12, weight: .semibold))
                .foregroundStyle(VentusPalette.ink)
            Text(label)
                .font(VentusFont.body(10))
                .foregroundStyle(VentusPalette.ink3)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.ultraThinMaterial)
        }
    }
}

private struct RuleCard: View {
    let rule: Rule

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: triggerIcon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(VentusPalette.accent)
                .frame(width: 32, height: 32)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(VentusPalette.accentTint)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(triggerDescription)
                    .font(VentusFont.body(12, weight: .semibold))
                    .foregroundStyle(VentusPalette.ink)
                Text("Priority \(rule.priority)")
                    .font(VentusFont.body(10))
                    .foregroundStyle(VentusPalette.ink3)
            }

            Spacer()

            Text(ventusProfileTitle(rule.profileName))
                .font(VentusFont.body(11, weight: .semibold))
                .foregroundStyle(VentusPalette.accentDeep)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background {
                    Capsule()
                        .fill(VentusPalette.accentTint)
                }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(VentusPalette.surface2.opacity(0.72))
        }
    }

    private var triggerDescription: String {
        switch rule.trigger {
        case .onBattery:
            return "When on battery power"
        case .onAC:
            return "When on AC power"
        case .clamshellClosed:
            return "When clamshell is closed"
        case .externalDisplayConnected:
            return "When an external display is connected"
        case .appRunning(let bundleID):
            return "When \(bundleID) is running"
        case .gameDetected:
            return "When a game is detected"
        case .timeWindow(let start, let end):
            return "Time window: \(start):00-\(end):00"
        }
    }

    private var triggerIcon: String {
        switch rule.trigger {
        case .onBattery:
            return "battery.50percent"
        case .onAC:
            return "powerplug.fill"
        case .clamshellClosed:
            return "macbook"
        case .externalDisplayConnected:
            return "display"
        case .appRunning:
            return "app.fill"
        case .gameDetected:
            return "gamecontroller.fill"
        case .timeWindow:
            return "clock.fill"
        }
    }
}
