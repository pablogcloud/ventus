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

    static let good = solid(0x009956)
    static let warn = solid(0xE89629)
    static let hot = solid(0xD73337)
    static let onAccent = solid(0xFFFFFF)
    static let gaugeCore = solid(0x17221C)
    static let thermalInk = solid(0xFFFFFF)
    static let thermalShadow = solid(0x17221C, alpha: 0.42)
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

struct VentusCardModifier: ViewModifier {
    let padding: CGFloat
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(VentusPalette.surface)
                    .shadow(color: VentusPalette.shadow, radius: 16, y: 8)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(VentusPalette.border, lineWidth: 1)
            }
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
