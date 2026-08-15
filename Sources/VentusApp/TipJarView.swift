import SwiftUI
import AppKit

/// Voluntary tip sheet. Framed as "how much did you like it" rather than a
/// price prompt — this is never a gate, and the dismiss is always plainly
/// available. Surfaces are solid, not glass: the window chrome already uses
/// glass and stacking it is banned by the design rules.
struct TipJarView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("tipAmount") private var amount: Double = 10

    private var style: CupStyle { CupStyle.interpolated(for: amount) }
    private var rounded: Int { KofiLinks.tiers[tierIndex] }

    /// The slider moves between the four tiers rather than over a continuous
    /// range, because Ko-fi can only be handed a fixed price — see `KofiLinks`.
    /// A continuous slider would show a number the checkout could not honour.
    private var tierIndex: Int {
        let nearest = KofiLinks.tiers.enumerated().min {
            abs(Double($0.element) - amount) < abs(Double($1.element) - amount)
        }
        return nearest?.offset ?? 1
    }

    private var tierBinding: Binding<Double> {
        Binding(
            get: { Double(tierIndex) },
            set: { amount = Double(KofiLinks.tiers[Int($0.rounded())]) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            // Real 3D scene. The soft contact shadow stays a SwiftUI ellipse
            // behind the transparent SCNView — cheaper and better-controlled
            // than a shadow-catching floor plane, and it tracks the sheet
            // background in both appearances.
            ZStack {
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [VentusPalette.shadow.opacity(0.5), .clear],
                            center: .center, startRadius: 0, endRadius: 62
                        )
                    )
                    .frame(width: 150, height: 34)
                    .blur(radius: 5)
                    .offset(y: 76)

                CupScene3D(amount: amount, reduceMotion: reduceMotion)
            }
            .frame(height: 210)
            .padding(.top, 4)

            amountReadout
            slider
            actions
        }
        .frame(width: 380)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .background(VentusPalette.panel)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 6) {
            Text("How much did you like Ventus?")
                .font(VentusFont.display(17, weight: .bold))
                .foregroundStyle(VentusPalette.ink)
                .multilineTextAlignment(.center)
            Text("Entirely optional — Ventus is free and stays free.")
                .font(VentusFont.body(12))
                .foregroundStyle(VentusPalette.ink2)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 22)
    }

    private var amountReadout: some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("$")
                    .font(VentusFont.number(20, weight: .semibold))
                    .foregroundStyle(VentusPalette.ink2)
                Text("\(rounded)")
                    .font(VentusFont.number(38, weight: .bold))
                    .foregroundStyle(VentusPalette.ink)
                    .contentTransition(.numericText())
            }
            Text(style.label)
                .font(VentusFont.body(12, weight: .medium))
                .foregroundStyle(VentusPalette.accentDeep)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: style.label)
        }
        .padding(.top, 10)
    }

    private var slider: some View {
        VStack(spacing: 6) {
            Slider(
                value: tierBinding,
                in: 0 ... Double(KofiLinks.tiers.count - 1),
                step: 1
            )
            .tint(VentusPalette.accent)
            .accessibilityLabel("Tip amount in US dollars")
            .accessibilityValue("\(rounded) dollars — \(style.label)")
            HStack {
                Text("$\(KofiLinks.tiers.first ?? 5)")
                Spacer()
                Text("$\(KofiLinks.tiers.last ?? 35)")
            }
            .font(VentusFont.body(10))
            .foregroundStyle(VentusPalette.ink3)
        }
        .padding(.top, 16)
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button {
                NSWorkspace.shared.open(KofiLinks.url(forTier: rounded))
                dismiss()
            } label: {
                Text(KofiLinks.hasFixedPrice(rounded)
                     ? "Tip $\(rounded) on Ko-fi"
                     : "Open Ko-fi")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(VentusButtonStyle(kind: .primary))
            .keyboardShortcut(.defaultAction)

            Button("Maybe later") { dismiss() }
                .buttonStyle(VentusButtonStyle(kind: .ghost))

            Text(KofiLinks.hasFixedPrice(rounded)
                 ? "Opens Ko-fi in your browser. No account needed to tip."
                 : "Opens Ko-fi in your browser, where you can pick any amount.")
                .font(VentusFont.body(10))
                .foregroundStyle(VentusPalette.ink3)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 18)
    }
}
