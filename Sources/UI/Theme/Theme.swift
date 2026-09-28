import AppKit
import SwiftUI

/// Fn-flow's design tokens (#4), shared by the app window and the overlay.
///
/// The look: a dark window frame with an icon rail, an inset pane over a pixel-cloud sky
/// (`CloudWallpaper`), and frosted dark-teal cards on top. The sky stays bright in both light
/// and dark mode, so the pane renders in light mode and the cards in dark mode. The accent is
/// the user's choice.
enum Theme {
    // MARK: Window frame
    static let chrome = Color(rgb: 0x242627)
    static let frameLine = Color(rgb: 0x121516)
    static let chromeText = Color(rgb: 0xE5E9E7)
    static let chromeMuted = Color(rgb: 0xA1A9A8)
    static let railIcon = Color(rgb: 0xB4C2C1)
    static let railSelected = Color(rgb: 0x263233)
    static let railHover = Color(rgb: 0x2C3536)

    // MARK: Directly on the pane (over the sky)
    static let paneText = Color(light: Color(rgb: 0x1B3035), dark: Color(rgb: 0xE8EFEC))
    static let paneMuted = Color(light: Color(rgb: 0x405B60), dark: Color(rgb: 0xBACAC7))
    static let paneDim = Color(light: Color(rgb: 0x4F6A6D), dark: Color(rgb: 0x9DB2B0))
    static let paneLine = Color(light: Color(rgb: 0x213C41).opacity(0.22), dark: Color(rgb: 0xF0F7EE).opacity(0.16))
    static let paneChip = Color(light: Color(rgb: 0xF3F6EC).opacity(0.5), dark: Color(rgb: 0xF3F6EC).opacity(0.12))
    static let paneChipLine = Color(light: Color(rgb: 0x193A3E).opacity(0.15), dark: Color(rgb: 0xF3F6EC).opacity(0.18))
    static let paneChipText = Color(light: Color(rgb: 0x23464A), dark: Color(rgb: 0xDCE8E5))
    static let paneHover = Color(light: Color(rgb: 0x1B3035).opacity(0.07), dark: Color.white.opacity(0.08))

    // MARK: Cards (frosted dark teal in both modes)
    static let card = Color(rgb: 0x233E41).opacity(0.84)
    static let cardHigh = Color(rgb: 0x3E5759).opacity(0.9)
    static let cardInput = Color(rgb: 0x11272B).opacity(0.58)
    static let cardLine = Color(rgb: 0xF0F7EE).opacity(0.2)
    static let cardLineSoft = Color(rgb: 0xF0F7EE).opacity(0.11)
    static let cardText = Color(rgb: 0xF7F8F2)
    static let cardMuted = Color(rgb: 0xD0DCDA)
    static let cardDim = Color(rgb: 0xA9BFBD)
    static let warning = Color(rgb: 0xDF9B7E)
    static let danger = Color(rgb: 0xF0B5A3)

    // MARK: Shape and spacing
    enum Radius {
        static let window: CGFloat = 24
        static let card: CGFloat = 20
        static let control: CGFloat = 8
        static let small: CGFloat = 6
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: Type
    enum Font {
        static let pageTitle = SwiftUI.Font.system(size: 13, weight: .bold)
        static let heading = SwiftUI.Font.system(size: 18, weight: .semibold)
        static let cardTitle = SwiftUI.Font.system(size: 16, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13)
        static let label = SwiftUI.Font.system(size: 12, weight: .semibold)
        static let small = SwiftUI.Font.system(size: 11)
        static let micro = SwiftUI.Font.system(size: 10, weight: .semibold, design: .monospaced)
        static let metric = SwiftUI.Font.system(size: 26, weight: .semibold)
    }
}

/// The user's accent color and the tints derived from it.
struct Accent: Equatable {
    let rgb: Int

    static let presets: [(name: String, rgb: Int)] = [
        ("Lime", 0xD6EE89), ("Sea glass", 0x85D8C7), ("Sand", 0xD7BD8D), ("Sky", 0x719BA5),
        ("Copper", 0xE6A578), ("Rose", 0xF0A3AD), ("Periwinkle", 0xA8B9FA),
    ]

    var name: String { Self.presets.first { $0.rgb == rgb }?.name ?? "Custom" }
    var color: Color { Color(rgb: rgb) }
    /// Text and icons on an accent-filled control.
    var ink: Color { Self.luminance(rgb) > 155 ? Color(rgb: 0x1B241C) : .white }
    /// Accent-colored text on a card: lightened for contrast on dark teal.
    var onCard: Color { Color(rgb: Self.mix(rgb, 0xFFFFFF, 0.67)) }
    /// Accent-colored text directly on the sky.
    var onPane: Color { Color(light: Color(rgb: Self.mix(rgb, 0x17363B, 0.43)), dark: Color(rgb: Self.mix(rgb, 0xFFFFFF, 0.75))) }
    /// A faint accent wash on a card (selected chips, badges).
    var soft: Color { Color(rgb: Self.mix(rgb, 0x233E41, 0.16)) }
    var line: Color { Color(rgb: Self.mix(rgb, 0x233E41, 0.4)) }
    /// Heatmap levels 1–4 on a card.
    func level(_ n: Int) -> Color {
        switch n {
        case ..<1: Theme.cardLineSoft
        case 1: Color(rgb: Self.mix(rgb, 0x233E41, 0.25))
        case 2: Color(rgb: Self.mix(rgb, 0x233E41, 0.47))
        case 3: Color(rgb: Self.mix(rgb, 0x233E41, 0.72))
        default: color
        }
    }

    /// `amount` of `a` mixed into `b`.
    static func mix(_ a: Int, _ b: Int, _ amount: Double) -> Int {
        func channel(_ shift: Int) -> Int {
            let x = Double((a >> shift) & 0xFF), y = Double((b >> shift) & 0xFF)
            return Int((x * amount + y * (1 - amount)).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }

    static func luminance(_ rgb: Int) -> Double {
        Double((rgb >> 16) & 0xFF) * 0.299 + Double((rgb >> 8) & 0xFF) * 0.587 + Double(rgb & 0xFF) * 0.114
    }

    /// 0xRRGGBB for a color picked in the system color panel.
    static func rgb(of color: Color) -> Int? {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return byte(c.redComponent) << 16 | byte(c.greenComponent) << 8 | byte(c.blueComponent)
    }
}

private struct AccentKey: EnvironmentKey {
    static let defaultValue = Accent(rgb: 0xD6EE89)
}

extension EnvironmentValues {
    var accent: Accent {
        get { self[AccentKey.self] }
        set { self[AccentKey.self] = newValue }
    }
}

extension Color {
    init(rgb: Int) {
        self.init(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }

    /// A color that follows the view's light or dark appearance.
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }
}
