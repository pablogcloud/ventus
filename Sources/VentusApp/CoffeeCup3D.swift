import SwiftUI

/// Continuously-interpolated appearance of the tip cup. Every field is a
/// number or colour so the whole illustration MORPHS between tiers instead of
/// snapping — dragging the slider should feel like one object changing, not
/// four sprites swapping.
struct CupStyle {
    var bodyHeight: CGFloat      // fraction of the canvas height
    var topWidth: CGFloat        // fraction of the canvas width
    var bottomWidth: CGFloat
    var bodyLight: Color         // left/lit side of the cylinder
    var bodyDark: Color          // right/shaded side
    var liquid: Color
    var liquidDeep: Color
    var sleeve: CGFloat          // 0…1 kraft sleeve opacity
    var whip: CGFloat            // 0…1 whipped-cream dome
    var straw: CGFloat           // 0…1 straw
    var steam: CGFloat           // 0…1 (hot drinks steam, cold ones don't)
    var label: String

    /// Keyframes at the four price anchors. Colours stay desaturated and
    /// slightly warm — no candy tones, per the AI-tell catalogue.
    private static let keyframes: [(amount: Double, style: CupStyle)] = [
        (5, CupStyle(
            bodyHeight: 0.44, topWidth: 0.30, bottomWidth: 0.23,
            bodyLight: Color(red: 0.85, green: 0.75, blue: 0.60),
            bodyDark:  Color(red: 0.63, green: 0.52, blue: 0.38),
            liquid:    Color(red: 0.32, green: 0.20, blue: 0.13),
            liquidDeep: Color(red: 0.20, green: 0.12, blue: 0.08),
            sleeve: 0, whip: 0, straw: 0, steam: 1,
            label: "A humble drip coffee"
        )),
        (10, CupStyle(
            bodyHeight: 0.52, topWidth: 0.36, bottomWidth: 0.27,
            bodyLight: Color(red: 0.96, green: 0.93, blue: 0.88),
            bodyDark:  Color(red: 0.80, green: 0.75, blue: 0.68),
            liquid:    Color(red: 0.55, green: 0.36, blue: 0.20),
            liquidDeep: Color(red: 0.36, green: 0.22, blue: 0.12),
            sleeve: 1, whip: 0, straw: 0, steam: 1,
            label: "A proper flat white"
        )),
        (20, CupStyle(
            bodyHeight: 0.58, topWidth: 0.38, bottomWidth: 0.30,
            bodyLight: Color(red: 0.93, green: 0.95, blue: 0.92),
            bodyDark:  Color(red: 0.76, green: 0.81, blue: 0.75),
            liquid:    Color(red: 0.53, green: 0.68, blue: 0.40),
            liquidDeep: Color(red: 0.38, green: 0.52, blue: 0.28),
            sleeve: 0.25, whip: 0.15, straw: 0.35, steam: 0.35,
            label: "Ceremonial-grade matcha"
        )),
        (35, CupStyle(
            bodyHeight: 0.66, topWidth: 0.42, bottomWidth: 0.31,
            bodyLight: Color(red: 0.95, green: 0.96, blue: 0.97),
            bodyDark:  Color(red: 0.78, green: 0.82, blue: 0.85),
            liquid:    Color(red: 0.72, green: 0.55, blue: 0.36),
            liquidDeep: Color(red: 0.45, green: 0.30, blue: 0.18),
            sleeve: 0, whip: 1, straw: 1, steam: 0,
            label: "The absurd whipped-cream frappé"
        )),
    ]

    static func interpolated(for amount: Double) -> CupStyle {
        let frames = keyframes
        if amount <= frames.first!.amount { return frames.first!.style }
        if amount >= frames.last!.amount { return frames.last!.style }
        for i in 0 ..< (frames.count - 1) {
            let a = frames[i], b = frames[i + 1]
            guard amount <= b.amount else { continue }
            // Ease the blend so each tier "settles" rather than sliding linearly.
            let raw = (amount - a.amount) / (b.amount - a.amount)
            let t = raw * raw * (3 - 2 * raw)   // smoothstep
            return CupStyle(
                bodyHeight: lerp(a.style.bodyHeight, b.style.bodyHeight, t),
                topWidth: lerp(a.style.topWidth, b.style.topWidth, t),
                bottomWidth: lerp(a.style.bottomWidth, b.style.bottomWidth, t),
                bodyLight: blend(a.style.bodyLight, b.style.bodyLight, t),
                bodyDark: blend(a.style.bodyDark, b.style.bodyDark, t),
                liquid: blend(a.style.liquid, b.style.liquid, t),
                liquidDeep: blend(a.style.liquidDeep, b.style.liquidDeep, t),
                sleeve: lerp(a.style.sleeve, b.style.sleeve, t),
                whip: lerp(a.style.whip, b.style.whip, t),
                straw: lerp(a.style.straw, b.style.straw, t),
                steam: lerp(a.style.steam, b.style.steam, t),
                // Label snaps at the midpoint — a half-blended sentence is worse
                // than a decisive one.
                label: t < 0.5 ? a.style.label : b.style.label
            )
        }
        return frames.last!.style
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
        a + (b - a) * CGFloat(t)
    }

    private static func blend(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let ca = NSColor(a).usingColorSpace(.sRGB) ?? .white
        let cb = NSColor(b).usingColorSpace(.sRGB) ?? .white
        return Color(
            .sRGB,
            red: Double(ca.redComponent + (cb.redComponent - ca.redComponent) * CGFloat(t)),
            green: Double(ca.greenComponent + (cb.greenComponent - ca.greenComponent) * CGFloat(t)),
            blue: Double(ca.blueComponent + (cb.blueComponent - ca.blueComponent) * CGFloat(t)),
            opacity: 1
        )
    }
}

/// Tapered cup body — wider at the rim than the base, with a softly rounded
/// bottom. Drawn rather than modelled: the "3D" reads from the cylinder
/// shading, the elliptical rim and the contact shadow, not from a 3D engine.
private struct CupBody: Shape {
    var topWidth: CGFloat
    var bottomWidth: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topWidth, bottomWidth) }
        set { topWidth = newValue.first; bottomWidth = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let midX = rect.midX
        let halfTop = rect.width * topWidth / 2
        let halfBottom = rect.width * bottomWidth / 2
        let corner = min(halfBottom * 0.55, rect.height * 0.16)

        var p = Path()
        p.move(to: CGPoint(x: midX - halfTop, y: rect.minY))
        p.addLine(to: CGPoint(x: midX - halfBottom, y: rect.maxY - corner))
        p.addQuadCurve(
            to: CGPoint(x: midX - halfBottom + corner, y: rect.maxY),
            control: CGPoint(x: midX - halfBottom, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: midX + halfBottom - corner, y: rect.maxY))
        p.addQuadCurve(
            to: CGPoint(x: midX + halfBottom, y: rect.maxY - corner),
            control: CGPoint(x: midX + halfBottom, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: midX + halfTop, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// The tip illustration. Soft-shaded, gently floating, morphing with `amount`.
struct CoffeeCup3D: View {
    let amount: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var style: CupStyle { CupStyle.interpolated(for: amount) }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let cupWidth = size.width
            let bodyH = size.height * style.bodyHeight
            let rimY = size.height * 0.30
            let rimW = cupWidth * style.topWidth
            let rimH = rimW * 0.26

            TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 30)) { timeline in
                // Slow idle bob; the illustration should feel alive but never
                // demand attention while you're reading the amount.
                let t = timeline.date.timeIntervalSinceReferenceDate
                let bob = reduceMotion ? 0 : sin(t * 1.1) * 3.5

                ZStack {
                    contactShadow(size: size, bodyH: bodyH, rimY: rimY, bob: bob)

                    steam(size: size, rimY: rimY, t: t)
                        .opacity(style.steam)

                    ZStack {
                        cupAndContents(size: size, cupWidth: cupWidth, bodyH: bodyH,
                                       rimY: rimY, rimW: rimW, rimH: rimH)
                        whippedCream(size: size, rimY: rimY, rimW: rimW)
                            .opacity(style.whip)
                        straw(size: size, rimY: rimY, rimW: rimW)
                            .opacity(style.straw)
                    }
                    .offset(y: bob)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style.label)
    }

    // MARK: - Pieces

    private func contactShadow(size: CGSize, bodyH: CGFloat, rimY: CGFloat, bob: CGFloat) -> some View {
        Ellipse()
            .fill(
                RadialGradient(
                    colors: [VentusPalette.shadow.opacity(0.55), .clear],
                    center: .center, startRadius: 0,
                    endRadius: size.width * style.bottomWidth * 0.75
                )
            )
            .frame(width: size.width * style.bottomWidth * 1.5,
                   height: size.width * style.bottomWidth * 0.34)
            .position(x: size.width / 2, y: rimY + bodyH + 10 + bob * 0.35)
            .blur(radius: 4)
    }

    private func cupAndContents(size: CGSize, cupWidth: CGFloat, bodyH: CGFloat,
                                rimY: CGFloat, rimW: CGFloat, rimH: CGFloat) -> some View {
        ZStack {
            // Body with cylinder shading: lit on the left, shaded to the right.
            CupBody(topWidth: style.topWidth, bottomWidth: style.bottomWidth)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: style.bodyDark.opacity(0.92), location: 0.0),
                            .init(color: style.bodyLight, location: 0.28),
                            .init(color: style.bodyLight, location: 0.46),
                            .init(color: style.bodyDark, location: 1.0),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .frame(width: cupWidth, height: bodyH)
                .position(x: size.width / 2, y: rimY + bodyH / 2)

            // Kraft sleeve (fades in for the mid tiers).
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.72, green: 0.58, blue: 0.42),
                                 Color(red: 0.55, green: 0.42, blue: 0.30)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .frame(width: rimW * 0.92, height: bodyH * 0.34)
                .position(x: size.width / 2, y: rimY + bodyH * 0.55)
                .opacity(style.sleeve)

            // Specular highlight — one soft band, no neon.
            Capsule()
                .fill(
                    LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.02)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .frame(width: rimW * 0.10, height: bodyH * 0.62)
                .position(x: size.width / 2 - rimW * 0.26, y: rimY + bodyH * 0.46)
                .blur(radius: 2)

            // Rim: outer ellipse (cup wall) then the liquid surface inside it.
            Ellipse()
                .fill(style.bodyDark)
                .frame(width: rimW, height: rimH)
                .position(x: size.width / 2, y: rimY)

            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [style.liquid, style.liquidDeep],
                        center: .init(x: 0.38, y: 0.34),
                        startRadius: 1, endRadius: rimW * 0.62
                    )
                )
                .frame(width: rimW * 0.86, height: rimH * 0.82)
                .position(x: size.width / 2, y: rimY)
        }
    }

    private func whippedCream(size: CGSize, rimY: CGFloat, rimW: CGFloat) -> some View {
        let w = rimW * 0.92
        return ZStack {
            ForEach(0 ..< 3, id: \.self) { i in
                let f = CGFloat(i)
                Ellipse()
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.99, green: 0.98, blue: 0.96),
                                     Color(red: 0.90, green: 0.87, blue: 0.83)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: w * (1 - f * 0.22), height: w * (0.34 - f * 0.05))
                    .position(x: size.width / 2 + (i.isMultiple(of: 2) ? -1 : 1) * f * 2,
                              y: rimY - f * (w * 0.12) - w * 0.04)
            }
            // Caramel drizzle — a single stroke, not a decorative flourish pile.
            Capsule()
                .fill(Color(red: 0.62, green: 0.40, blue: 0.20).opacity(0.75))
                .frame(width: w * 0.42, height: 2.5)
                .rotationEffect(.degrees(-8))
                .position(x: size.width / 2, y: rimY - w * 0.13)
        }
    }

    private func straw(size: CGSize, rimY: CGFloat, rimW: CGFloat) -> some View {
        Capsule()
            .fill(
                LinearGradient(colors: [VentusPalette.accent, VentusPalette.accentDeep],
                               startPoint: .top, endPoint: .bottom)
            )
            .frame(width: rimW * 0.085, height: rimW * 0.78)
            .rotationEffect(.degrees(14))
            .position(x: size.width / 2 + rimW * 0.20, y: rimY - rimW * 0.22)
    }

    private func steam(size: CGSize, rimY: CGFloat, t: TimeInterval) -> some View {
        ZStack {
            ForEach(0 ..< 2, id: \.self) { i in
                let phase = t * 0.9 + Double(i) * 1.7
                let drift = CGFloat(sin(phase)) * 5
                Capsule()
                    .fill(
                        LinearGradient(colors: [.clear, VentusPalette.ink3.opacity(0.30), .clear],
                                       startPoint: .bottom, endPoint: .top)
                    )
                    .frame(width: 4, height: size.height * 0.16)
                    .offset(x: CGFloat(i == 0 ? -8 : 9) + drift,
                            y: -CGFloat((sin(phase * 0.5) + 1) * 4))
                    .position(x: size.width / 2, y: rimY - size.height * 0.11)
                    .blur(radius: 2.5)
            }
        }
    }
}
