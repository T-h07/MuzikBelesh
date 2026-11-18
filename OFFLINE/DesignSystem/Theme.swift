import SwiftUI
import UIKit

// MARK: - Colour value

/// An opaque 24-bit sRGB colour. Serialized as canonical `#RRGGBB`: no locale, no floating
/// point round trips, no alpha (custom colours are always fully opaque).
struct ThemeRGB: Equatable, Hashable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8) { self.red = red; self.green = green; self.blue = blue }

    /// Strict parser: `#RRGGBB` or `RRGGBB`, hex digits only. Anything else is rejected.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, text.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }),
              let value = UInt32(text, radix: 16) else { return nil }
        red = UInt8((value >> 16) & 0xFF); green = UInt8((value >> 8) & 0xFF); blue = UInt8(value & 0xFF)
    }

    /// Converts any SwiftUI colour (including Display P3 from the system picker) to sRGB,
    /// clamps to the sRGB gamut and drops transparency.
    init?(color: Color) {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = UIColor(color).cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3 else { return nil }
        func byte(_ value: CGFloat) -> UInt8? {
            guard value.isFinite else { return nil }
            return UInt8((min(max(value, 0), 1) * 255).rounded())
        }
        guard let r = byte(components[0]), let g = byte(components[1]), let b = byte(components[2]) else { return nil }
        self.init(red: r, green: g, blue: b)
    }

    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
    var color: Color { Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, opacity: 1) }

    /// WCAG 2.x relative luminance.
    var luminance: Double {
        func channel(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    func contrast(with other: ThemeRGB) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Linear sRGB-byte mix toward `other`; `amount` 0…1.
    func mixed(with other: ThemeRGB, amount: Double) -> ThemeRGB {
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(a) + (Double(b) - Double(a)) * amount).rounded()) }
        return ThemeRGB(red: mix(red, other.red), green: mix(green, other.green), blue: mix(blue, other.blue))
    }

    static let black = ThemeRGB(red: 0, green: 0, blue: 0)
    static let white = ThemeRGB(red: 255, green: 255, blue: 255)
}

// MARK: - Presets and selection

enum ThemePreset: String, CaseIterable, Identifiable, Sendable {
    case lime, purple, violet, blue, cyan, pink, red, orange
    var id: String { rawValue }

    var name: String {
        switch self {
        case .lime: return "Original Lime"
        case .purple: return "Purple"
        case .violet: return "Violet"
        case .blue: return "Blue"
        case .cyan: return "Cyan"
        case .pink: return "Pink"
        case .red: return "Red"
        case .orange: return "Orange"
        }
    }

    /// Canonical sRGB values. Each clears 4.5:1 against the pure-black background, so no
    /// preset needs a presentation adjustment.
    var rgb: ThemeRGB {
        switch self {
        case .lime: return ThemeRGB(hex: "#D6EEA3")!
        case .purple: return ThemeRGB(hex: "#B69CFB")!
        case .violet: return ThemeRGB(hex: "#9670F7")!
        case .blue: return ThemeRGB(hex: "#60A5FA")!
        case .cyan: return ThemeRGB(hex: "#22D3EE")!
        case .pink: return ThemeRGB(hex: "#F472B6")!
        case .red: return ThemeRGB(hex: "#FB7185")!
        case .orange: return ThemeRGB(hex: "#FB923C")!
        }
    }
}

enum ThemeSelection: Equatable, Sendable {
    case preset(ThemePreset)
    case custom

    static let `default` = ThemeSelection.preset(.lime)

    var identifier: String {
        switch self { case .preset(let preset): return preset.rawValue; case .custom: return "custom" }
    }

    init?(identifier: String) {
        if identifier == "custom" { self = .custom }
        else if let preset = ThemePreset(rawValue: identifier) { self = .preset(preset) }
        else { return nil }
    }
}

// MARK: - Semantic palette

/// Every accent role the interface uses, derived deterministically from one chosen colour.
/// Backgrounds, text and status colours (success, warning, error, destructive) are not part of
/// the palette: they stay in `AppColors` and never follow the user's accent.
struct ThemePalette: Equatable {
    /// Minimum contrast of accent text and controls against the black background (WCAG AA text).
    static let minimumContrast = 4.5

    /// The colour the user chose, exactly as saved (used for swatches).
    let chosen: ThemeRGB
    /// The colour used for accent text, icons, controls and fills on black. Equal to `chosen`
    /// unless `chosen` is too dark to read, in which case it is mixed toward white just enough.
    let accentRGB: ThemeRGB
    /// Text and icons placed on an accent fill: black or white, whichever contrasts more.
    let onAccentRGB: ThemeRGB

    init(chosen: ThemeRGB) {
        self.chosen = chosen
        var visible = chosen
        var step = 0
        while visible.contrast(with: .black) < Self.minimumContrast && step < 20 {
            step += 1
            visible = chosen.mixed(with: .white, amount: Double(step) * 0.05)
        }
        accentRGB = visible
        onAccentRGB = visible.contrast(with: .black) >= visible.contrast(with: .white) ? .black : .white
    }

    static let `default` = ThemePalette(chosen: ThemePreset.lime.rgb)

    var isAdjustedForContrast: Bool { accentRGB != chosen }

    var accent: Color { accentRGB.color }
    var onAccent: Color { onAccentRGB.color }
    var accentMuted: Color { accent.opacity(0.6) }
    var accentSubtleBackground: Color { accent.opacity(0.14) }
    var accentBorder: Color { accent.opacity(0.5) }
    var accentSelection: Color { accent }
    var chartPrimary: Color { accent }
    var chartSecondary: Color { accent.opacity(0.32) }
    var controlTint: Color { accent }
}

private struct ThemePaletteKey: EnvironmentKey {
    static let defaultValue = ThemePalette.default
}

extension EnvironmentValues {
    /// The current accent palette. Set once at the root from `ThemeService`; every view that
    /// reads it re-renders when the theme changes, and nothing else does.
    var themePalette: ThemePalette {
        get { self[ThemePaletteKey.self] }
        set { self[ThemePaletteKey.self] = newValue }
    }
}
