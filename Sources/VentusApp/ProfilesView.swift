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

            AutoCard(
                isActive: config.pinnedProfile == nil,
                activeRule: observer.status?.activeRule,
                resolvedProfile: observer.status?.activeProfile,
                isApplying: applyingProfile == Self.autoToken,
                action: activateAuto
            )

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

            RulesEditor(config: config, observer: observer)
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

    /// Sentinel for the Auto card's spinner — it is not a profile name, so it
    /// can never collide with one.
    fileprivate static let autoToken = "\u{0}auto"

    private func activateAuto() {
        applyingProfile = Self.autoToken
        feedback = nil
        Task {
            if await observer.setAutoProfile() {
                // The daemon decides what runs now; reflect whatever it picked.
                syncSelection()
            } else {
                feedback = "The daemon could not switch to automatic."
            }
            applyingProfile = nil
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

/// Hands profile choice back to the rules. Sits above the profile grid because
/// it is the default state, not an extra mode: picking a profile below is what
/// suspends it.
private struct AutoCard: View {
    let isActive: Bool
    let activeRule: String?
    let resolvedProfile: String?
    let isApplying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isActive ? VentusPalette.accent : VentusPalette.ink3)
                    .frame(width: 34, height: 34)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isActive ? VentusPalette.accentTint : VentusPalette.lift)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Automatic")
                        .font(VentusFont.body(13, weight: .semibold))
                        .foregroundStyle(VentusPalette.ink)
                    Text(subtitle)
                        .font(VentusFont.body(11))
                        .foregroundStyle(VentusPalette.ink2)
                        .lineLimit(1)
                }

                Spacer()

                if isApplying {
                    ProgressView().controlSize(.small).tint(VentusPalette.accent)
                } else if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(VentusPalette.accent)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(isActive ? VentusPalette.accentTint.opacity(0.5) : VentusPalette.surface2.opacity(0.72))
                    .overlay {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(
                                isActive ? VentusPalette.accent.opacity(0.5) : .clear,
                                lineWidth: 1
                            )
                    }
            }
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        guard isActive else { return "Let rules choose the profile" }
        if let activeRule, let resolvedProfile {
            return "\(activeRule) → \(ventusProfileTitle(resolvedProfile))"
        }
        if let resolvedProfile {
            return "No rule matches — using \(ventusProfileTitle(resolvedProfile))"
        }
        return "Rules choose the profile"
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
                .fill(VentusPalette.lift)
        }
    }
}
