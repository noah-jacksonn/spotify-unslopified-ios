import SwiftUI
import UIKit

struct Palette {
    var background: Color
    var surface: Color
    var raised: Color
    var text: Color
    var muted: Color
    var line: Color
    var accent: Color
    /// Text/icons drawn on `accent`.
    var onAccent: Color
}

/// The app's look, locked in from Noah's on-phone segtest (2026-10-02):
/// the extension's Ink palette, SF Rounded, a soft accent glow behind the
/// page, calm easing, a List Home with round-cornered art, the wordmark
/// header, airy spacing, a full-width Bar mini player and the Poster full
/// player. Screens read it from `@Environment(\.look)`.
struct Look {
    var isDark: Bool
    var palette: Palette
    /// The color of the glow behind the page: the current song's art
    /// (`ArtGlow`), else the accent.
    var glow: Color

    init(isDark: Bool, artTint: UIColor? = nil) {
        let palette = isDark ? Self.inkDark : Self.inkLight
        self.isDark = isDark
        self.palette = palette
        glow = artTint.map { Self.glowColor(from: $0, isDark: isDark) } ?? palette.accent
    }

    /// Keeps the art's hue but evens out saturation and brightness, so a
    /// dull or neon cover still makes a soft glow: light and pale on Ink
    /// dark, deeper on light (matching how each accent sits).
    private static func glowColor(from tint: UIColor, isDark: Bool) -> Color {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        tint.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return isDark
            ? Color(hue: hue, saturation: min(max(saturation, 0.35), 0.55), brightness: 0.95)
            : Color(hue: hue, saturation: min(max(saturation, 0.45), 0.8), brightness: 0.78)
    }

    // MARK: Type

    func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    func display(_ size: CGFloat) -> Font { font(size, .bold) }

    let titleTracking: CGFloat = -0.4

    // MARK: Space and shape

    let gap: CGFloat = 22
    let margin: CGFloat = 20
    let hairline: CGFloat = 0.5

    func artRadius(_ size: CGFloat) -> CGFloat { size * 0.32 }

    // MARK: Motion

    let animation: Animation = .easeInOut(duration: 0.35)

    // MARK: Palettes

    private static let inkDark = Palette(
        background: hex(0x090d14), surface: hex(0x111823), raised: hex(0x1c293b), text: hex(0xf1f5fb),
        muted: hex(0x9caac0), line: hex(0x293449), accent: hex(0xbcd7ff), onAccent: hex(0x0b1220)
    )
    private static let inkLight = Palette(
        background: hex(0xf4f6fa), surface: hex(0xffffff), raised: hex(0xe8edf5), text: hex(0x0d1420),
        muted: hex(0x5d6b80), line: hex(0xd5dce8), accent: hex(0x2c5bd0), onAccent: hex(0xffffff)
    )

    private static func hex(_ value: UInt32) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255,
              blue: Double(value & 0xff) / 255)
    }
}

private struct LookKey: EnvironmentKey {
    static let defaultValue = Look(isDark: true)
}

extension EnvironmentValues {
    var look: Look {
        get { self[LookKey.self] }
        set { self[LookKey.self] = newValue }
    }
}

extension View {
    /// The raised surface: a different-shade fill, not an outline.
    func surface<S: Shape>(_ look: Look, in shape: S, raised: Bool = false) -> some View {
        background(raised ? look.palette.raised : look.palette.surface, in: shape)
    }
}
