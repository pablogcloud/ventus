import AppKit
import CoreText
import SwiftUI

enum VentusPalette {
    static let accent = dynamic("accent", light: 0x00884B, dark: 0x43C07A)
    static let accentHover = dynamic("accentHover", light: 0x007338, dark: 0x59D38C)
    static let accentDeep = dynamic("accentDeep", light: 0x005928, dark: 0x79DD9F)
    static let accentTint = dynamic("accentTint", light: 0xE0F5E6, dark: 0x173523)
    static let accentTint2 = dynamic("accentTint2", light: 0xD7F4E0, dark: 0x1B412A)

    static let bg = dynamic("bg", light: 0xF8FBF8, dark: 0x0B110E)
    static let panel = dynamic("panel", light: 0xEFF5F0, dark: 0x111814)
    static let surface = dynamic("surface", light: 0xFFFFFF, dark: 0x161F1A)
    static let surface2 = dynamic("surface2", light: 0xE8F6EC, dark: 0x1E2A23)
    static let surface3 = dynamic("surface3", light: 0xDCF2E3, dark: 0x26342C)

    static let border = dynamic("border", light: 0xE0E7E2, dark: 0x29332D)
    static let borderStrong = dynamic("borderStrong", light: 0xC2D7C9, dark: 0x3A4D42)
    static let ink = dynamic("ink", light: 0x17221C, dark: 0xEAF0EB)
    static let ink2 = dynamic("ink2", light: 0x4F5C54, dark: 0xA1AFA5)
    static let ink3 = dynamic("ink3", light: 0x6B7870, dark: 0x77847B)

    // Semantic status colors double as small feedback TEXT, so the light
    // variants are darkened to clear WCAG 4.5:1 on the near-white light
    // surface (the vivid originals were ~2.4–3.9:1 there); dark variants stay
    // vivid against the dark surface.
    static let good = dynamic("good", light: 0x00733D, dark: 0x2FC076)
    static let warn = dynamic("warn", light: 0x9A6300, dark: 0xF0A64A)
    static let hot = dynamic("hot", light: 0xC01F26, dark: 0xF06E72)
    static let onAccent = solid(0xFFFFFF)
    static let gaugeCore = dynamic("gaugeCore", light: 0xFFFFFF, dark: 0x17221C)
    static let thermalInk = dynamic("thermalInk", light: 0x17221C, dark: 0xFFFFFF)
    static let thermalShadow = dynamic(
        "thermalShadow",
        light: 0x355C43, dark: 0x17221C,
        lightAlpha: 0.18, darkAlpha: 0.42
    )

    /// Recessed area inside a glass card (segment containers, schematic box):
    /// slightly dark in BOTH appearances — a white tint disappears on light.
    static let well = dynamic("well", light: 0x17221C, dark: 0x000000,
                              lightAlpha: 0.06, darkAlpha: 0.14)
    /// Raised area inside a glass card (fan cards, metric chips): light lift
    /// in dark mode, subtle dark lift in light mode.
    static let lift = dynamic("lift", light: 0x17221C, dark: 0xFFFFFF,
                              lightAlpha: 0.045, darkAlpha: 0.07)
    /// Dim backing under glassEffect for backdrop legibility.
    static let glassTint = dynamic("glassTint", light: 0x17221C, dark: 0x000000,
                                   lightAlpha: 0.05, darkAlpha: 0.16)
    static let shadow = dynamic(
        "shadow",
        light: 0x355C43,
        dark: 0x000000,
        lightAlpha: 0.12,
        darkAlpha: 0.42
    )

    static let thermalStops: [(temperature: Double, color: Color)] = [
        (40, solid(0x3A6B8C)),
        (52, solid(0x4E8C86)),
        (64, solid(0xC08A3E)),
        (72, solid(0xD07B3C)),
        (85, solid(0xCF4B39)),
    ]

    /// Maps a temperature onto the thermal gradient normalized to `range`
    /// instead of the absolute 40–85° span — a narrow live range makes the
    /// hottest component visibly stand out even when everything sits within
    /// a few degrees. Absolute overheat (≥85°C) always reads hot-red.
    static func adaptiveThermal(_ temperature: Double, range: ClosedRange<Double>) -> Color {
        if temperature >= 85 { return hot }
        let span = max(range.upperBound - range.lowerBound, 0.001)
        let fraction = min(max((temperature - range.lowerBound) / span, 0), 1)
        let scaleLow = thermalStops.first!.temperature
        let scaleHigh = thermalStops.last!.temperature
        return thermal(scaleLow + fraction * (scaleHigh - scaleLow))
    }

    static func thermal(_ temperature: Double) -> Color {
        let clamped = min(max(temperature, thermalStops[0].temperature), thermalStops.last!.temperature)
        for index in 0..<(thermalStops.count - 1) {
            let lower = thermalStops[index]
            let upper = thermalStops[index + 1]
            guard clamped <= upper.temperature else { continue }
            let fraction = (clamped - lower.temperature) / (upper.temperature - lower.temperature)
            let lowerColor = thermalHex(at: index)
            let upperColor = thermalHex(at: index + 1)
            return Color(
                .sRGB,
                red: lowerColor.red + (upperColor.red - lowerColor.red) * fraction,
                green: lowerColor.green + (upperColor.green - lowerColor.green) * fraction,
                blue: lowerColor.blue + (upperColor.blue - lowerColor.blue) * fraction,
                opacity: 1
            )
        }
        return thermalStops.last!.color
    }

    private static let thermalHexValues: [UInt32] = [
        0x3A6B8C, 0x4E8C86, 0xC08A3E, 0xD07B3C, 0xCF4B39,
    ]

    private static func thermalHex(at index: Int) -> (red: Double, green: Double, blue: Double) {
        let value = thermalHexValues[index]
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }

    private static func dynamic(
        _ name: String,
        light: UInt32,
        dark: UInt32,
        lightAlpha: CGFloat = 1,
        darkAlpha: CGFloat = 1
    ) -> Color {
        Color(
            nsColor: NSColor(
                name: NSColor.Name("Ventus.\(name)"),
                dynamicProvider: { appearance in
                    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    return nsColor(
                        hex: isDark ? dark : light,
                        alpha: isDark ? darkAlpha : lightAlpha
                    )
                }
            )
        )
    }

    private static func solid(_ hex: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: nsColor(hex: hex, alpha: alpha))
    }

    private static func nsColor(hex: UInt32, alpha: CGFloat) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

enum VentusFont {
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .custom("Sora", size: size).weight(weight)
    }

    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Instrument Sans", size: size).weight(weight)
    }

    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .custom("Sora", size: size).weight(weight).monospacedDigit()
    }
}

enum VentusTheme {
    @discardableResult
    static func registerFonts() -> Bool {
        let names = ["Sora", "InstrumentSans"]
        var urls: [URL] = []

        if let resources = Bundle.main.resourceURL {
            urls += names.compactMap {
                resources
                    .appendingPathComponent("Fonts", isDirectory: true)
                    .appendingPathComponent("\($0).ttf")
            }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        }

        #if SWIFT_PACKAGE
        if urls.isEmpty {
            urls += names.compactMap {
                Bundle.module.url(forResource: $0, withExtension: "ttf", subdirectory: "Fonts")
            }
        }
        #endif

        for url in Set(urls) {
            var error: Unmanaged<CFError>?
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        }

        let families = Set(NSFontManager.shared.availableFontFamilies)
        let soraAvailable = families.contains("Sora")
        let instrumentAvailable = families.contains("Instrument Sans")
        print("[Ventus] Font registration: Sora=\(soraAvailable) Instrument Sans=\(instrumentAvailable)")
        return soraAvailable && instrumentAvailable
    }
}

import AppKit

/// Behind-window liquid-glass backdrop: makes the hosting window non-opaque
/// and renders the system blur. The green identity lives in accents on top,
/// not in the chrome.
struct GlassBackdrop: NSViewRepresentable {
    final class BackdropView: NSVisualEffectView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isOpaque = false
            window?.backgroundColor = .clear
        }
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = BackdropView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Native macOS 26 Liquid Glass on an explicit shape, with a frosted-material
/// fallback for macOS 14/15. Vault lesson (Open Spotlight): blanket material
/// layers inside a transparent panel composite as flat rectangles — the glass
/// must be the shape itself via glassEffect(in:), and glass shapes must not
/// nest (inner elements stay subtle materials/tints).
struct VentusGlassModifier: ViewModifier {
    var radius: CGFloat = 16

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // ONE shape only. Previously a separate tint RoundedRectangle behind
            // the glass (plus a redundant clipShape on the caller) stacked three
            // rounded shapes that didn't perfectly align — the tint rect peeked
            // out as a ghost double-corner. The tint now rides inside the glass
            // via .tint(), so the glassEffect is the single source of the shape,
            // edge, and clip. A dim tint keeps backdrop text unreadable while the
            // liquid lensing survives.
            content
                .glassEffect(
                    .regular.tint(VentusPalette.glassTint),
                    in: RoundedRectangle(cornerRadius: radius, style: .continuous)
                )
                // `in:` shapes the tint, but the glass MATERIAL still renders
                // across the view's full rectangular bounds — visible as a
                // lightened square halo around the card, and as a square
                // silhouette for any shadow cast from it. Clipping to the same
                // shape confines the material too, so the composed view's alpha
                // really is the rounded card.
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: radius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(VentusPalette.border, lineWidth: 1)
                }
        }
    }
}

enum VentusMetrics {
    /// Corner radius of the menu-bar panel. Shared so the SwiftUI glass shape
    /// and the AppKit layer clip cannot drift apart — if they disagree, the
    /// difference shows as a square shoulder at the corners.
    static let panelCornerRadius: CGFloat = 16

}

extension View {
    func ventusGlass(radius: CGFloat = VentusMetrics.panelCornerRadius) -> some View {
        modifier(VentusGlassModifier(radius: radius))
    }
}

struct VentusCardModifier: ViewModifier {
    let padding: CGFloat
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .ventusGlass(radius: radius)
    }
}

extension View {
    func ventusCard(padding: CGFloat = 18, radius: CGFloat = 18) -> some View {
        modifier(VentusCardModifier(padding: padding, radius: radius))
    }
}

struct VentusButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case ghost
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        VentusButtonStyleBody(configuration: configuration, kind: kind)
    }
}

private struct VentusButtonStyleBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: VentusButtonStyle.Kind
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(VentusFont.body(13, weight: .semibold))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 16)
            .frame(minHeight: 34)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(backgroundColor)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : (isHovering ? 1.01 : 1))
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.16), value: isHovering)
            .onHover { isHovering = $0 }
    }

    private var foregroundColor: Color {
        kind == .primary ? VentusPalette.onAccent : VentusPalette.ink
    }

    private var backgroundColor: Color {
        switch kind {
        case .primary:
            return isHovering ? VentusPalette.accentHover : VentusPalette.accent
        case .secondary:
            return isHovering ? VentusPalette.surface2 : VentusPalette.surface
        case .ghost:
            return isHovering ? VentusPalette.accentTint : VentusPalette.surface.opacity(0.001)
        }
    }

    private var borderColor: Color {
        kind == .primary ? VentusPalette.accent : VentusPalette.border
    }
}
