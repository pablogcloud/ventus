import SwiftUI
import VentusCore

struct VentusMark: View {
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 6 : 9) {
            VStack(alignment: .leading, spacing: 2.5) {
                Capsule()
                    .fill(VentusPalette.accent)
                    .frame(width: compact ? 14 : 18, height: 3)
                Capsule()
                    .fill(VentusPalette.accentDeep)
                    .frame(width: compact ? 9 : 11, height: 3)
                Capsule()
                    .fill(VentusPalette.accentHover)
                    .frame(width: compact ? 11 : 15, height: 3)
            }
            Text("Ventus")
                .font(VentusFont.display(compact ? 14 : 16, weight: .bold))
                .foregroundStyle(VentusPalette.ink)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ventus")
    }
}

struct VentusSectionHeader: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(VentusFont.display(11, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(VentusPalette.accentDeep)
            Spacer()
            if let detail {
                Text(detail)
                    .font(VentusFont.body(12))
                    .foregroundStyle(VentusPalette.ink3)
            }
        }
    }
}

struct VentusSegmentButton: View {
    let title: String
    let isSelected: Bool
    var isEnabled = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(VentusFont.body(12, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(
                    isSelected ? VentusPalette.accentDeep : VentusPalette.ink2
                )
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 6)
                .frame(height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(background)
                        .shadow(
                            color: isSelected ? VentusPalette.shadow : VentusPalette.shadow.opacity(0),
                            radius: 4,
                            y: 2
                        )
                }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .scaleEffect(isHovering && isEnabled ? 1.015 : 1)
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var background: Color {
        if isSelected {
            return VentusPalette.surface
        }
        return isHovering ? VentusPalette.accentTint : VentusPalette.surface.opacity(0.001)
    }
}

struct VentusStatusPill: View {
    let text: String
    let tone: Color

    var body: some View {
        Text(text)
            .font(VentusFont.body(11, weight: .semibold))
            .foregroundStyle(tone)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background {
                Capsule()
                    .fill(VentusPalette.accentTint)
            }
    }
}

struct VentusUnavailableState: View {
    let title: String
    let message: String
    var buttonTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(VentusPalette.warn)
            Text(title)
                .font(VentusFont.display(16, weight: .bold))
                .foregroundStyle(VentusPalette.ink)
            Text(message)
                .font(VentusFont.body(12))
                .foregroundStyle(VentusPalette.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .buttonStyle(VentusButtonStyle(kind: .secondary))
            }
        }
        .frame(maxWidth: 320)
        .padding(24)
    }
}

struct MainWindowView: View {
    @ObservedObject var observer: DaemonClientObserver
    @State private var selectedTab = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fanControlAvailable: Bool {
        observer.status?.isFanControlAvailable ?? true
    }

    var body: some View {
        VStack(spacing: 0) {
            windowHeader
            ZStack {
                Color.clear
                selectedContent
                    .id(selectedTab)
                    .transition(
                        reduceMotion
                            ? .identity
                            : .opacity.combined(with: .move(edge: .bottom))
                    )
            }
        }
        .foregroundStyle(VentusPalette.ink)
        .frame(minWidth: 780, idealWidth: 920, minHeight: 620, idealHeight: 720)
        .background(GlassBackdrop().ignoresSafeArea())
        .onChange(of: fanControlAvailable) { _, isAvailable in
            if !isAvailable {
                selectedTab = 0
            }
        }
        .animation(
            reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86),
            value: selectedTab
        )
    }

    private var windowHeader: some View {
        HStack(spacing: 18) {
            VentusMark(compact: true)

            HStack(spacing: 4) {
                tabButton("Dashboard", index: 0)
                if fanControlAvailable {
                    tabButton("Curves", index: 1)
                    tabButton("Profiles", index: 2)
                }
            }
            .padding(3)
            .frame(width: fanControlAvailable ? 300 : 116)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(VentusPalette.border, lineWidth: 1)
            }

            Spacer()

            HStack(spacing: 7) {
                Circle()
                    .fill(observer.isConnected ? VentusPalette.good : VentusPalette.warn)
                    .frame(width: 7, height: 7)
                Text(observer.isConnected ? "Daemon connected" : "Connecting")
                    .font(VentusFont.body(11, weight: .medium))
                    .foregroundStyle(VentusPalette.ink2)
            }
        }
        .padding(.leading, 78)
        .padding(.trailing, 18)
        .frame(height: 48)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(VentusPalette.border)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedTab {
        case 1:
            CurvesTabView(observer: observer)
        case 2:
            ProfilesTabView(observer: observer)
        default:
            DashboardTabView(observer: observer)
        }
    }

    private func tabButton(_ title: String, index: Int) -> some View {
        VentusSegmentButton(
            title: title,
            isSelected: selectedTab == index,
            action: { selectedTab = index }
        )
    }
}

func ventusProfileTitle(_ profile: String) -> String {
    switch profile {
    case "quiet":
        return "Quiet"
    case "balanced":
        return "Balanced"
    case "performance":
        return "Perf"
    case "auto-apple":
        return "Auto"
    default:
        return profile.replacingOccurrences(of: "-", with: " ").capitalized
    }
}

func ventusFanLabel(index: Int) -> String {
    switch index {
    case 0:
        return "LEFT · GPU-weighted"
    case 1:
        return "RIGHT · P-core"
    default:
        return "FAN \(index + 1)"
    }
}

func ventusSensorLabel(_ group: String) -> String {
    switch group {
    case "cpu_perf":
        return "P-cores"
    case "cpu_eff":
        return "E-cores"
    case "gpu":
        return "GPU"
    case "soc":
        return "SoC"
    case "battery":
        return "Battery"
    case "nand":
        return "NAND"
    case "other":
        return "Board"   // tdev1–8: board/device sensors near the die
    default:
        return group.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
