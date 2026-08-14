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
            bodyLight: Color(red: 0.78, green: 0.65, blue: 0.47),
            bodyDark:  Color(red: 0.52, green: 0.40, blue: 0.27),
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
            sleeve: 0.25, whip: 0, straw: 0.35, steam: 0.35,
            label: "Ceremonial-grade matcha"
        )),
        (35, CupStyle(
            bodyHeight: 0.66, topWidth: 0.42, bottomWidth: 0.31,
            bodyLight: Color(red: 0.86, green: 0.90, blue: 0.94),
            bodyDark:  Color(red: 0.60, green: 0.67, blue: 0.74),
            liquid:    Color(red: 0.72, green: 0.55, blue: 0.36),
            liquidDeep: Color(red: 0.45, green: 0.30, blue: 0.18),
            sleeve: 0, whip: 1, straw: 1, steam: 0,
            label: "The absurd whipped-cream frappé"
        )),
    ]

    /// Numeric-only slice of the keyframes. `interpolated` builds `Color`
    /// values, and converting those touches AppKit — the render thread needs
    /// the shape weights without dragging colour conversion along.
    struct ShapeWeights {
        var whip: CGFloat
        var straw: CGFloat
        var steam: CGFloat
    }

    static func shape(for amount: Double) -> ShapeWeights {
        let frames = keyframes
        func w(_ f: CupStyle) -> ShapeWeights {
            ShapeWeights(whip: f.whip, straw: f.straw, steam: f.steam)
        }
        if amount <= frames.first!.amount { return w(frames.first!.style) }
        if amount >= frames.last!.amount { return w(frames.last!.style) }
        for i in 0 ..< (frames.count - 1) {
            let a = frames[i], b = frames[i + 1]
            guard amount <= b.amount else { continue }
            let raw = (amount - a.amount) / (b.amount - a.amount)
            let t = CGFloat(raw * raw * (3 - 2 * raw))
            return ShapeWeights(
                whip: a.style.whip + (b.style.whip - a.style.whip) * t,
                straw: a.style.straw + (b.style.straw - a.style.straw) * t,
                steam: a.style.steam + (b.style.steam - a.style.steam) * t
            )
        }
        return w(frames.last!.style)
    }

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
