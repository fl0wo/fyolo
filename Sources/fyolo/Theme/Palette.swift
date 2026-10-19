import AppKit
import SwiftUI

/// fyolo's status colors: one hue per meaning, tuned once per appearance, and shared
/// by every surface that marks the state of a file or a line — the diff's washes, the
/// git lists' `+N −M` and status letters, the file tree's backgrounds and names.
///
/// Before this, each of those picked its own `.green` and `.red`, so the same "added"
/// was three different greens a few points apart. A surface takes a hue from here and
/// one of the named strengths below; it does not invent a shade.
///
/// Bases are picked per appearance rather than lightened from one color: a green that
/// reads as green on white is muddy on black, and a red that reads on black glares on
/// white. `NSColor.systemGreen`/`.systemRed` are tuned for controls on a system
/// background, not for a wash on an arbitrary terminal background.
enum Palette {
    enum Hue: CaseIterable {
        /// Added: new files, added lines, test code.
        case green
        /// Removed, and wrong: deleted lines, errors.
        case red
        /// Changed in place.
        case blue
        /// Moved or copied.
        case orange
        /// Needs a decision: conflicts.
        case yellow
        /// Not written by hand: lockfiles and generated code.
        case brown
        /// Not part of the work: ignored files.
        case grey
    }

    static func base(_ hue: Hue, dark: Bool) -> NSColor {
        switch (hue, dark) {
        case (.green, false): NSColor(srgbRed: 0.051, green: 0.745, blue: 0.306, alpha: 1)
        case (.green, true): NSColor(srgbRed: 0.369, green: 0.800, blue: 0.443, alpha: 1)
        case (.red, false): NSColor(srgbRed: 1.000, green: 0.180, blue: 0.247, alpha: 1)
        case (.red, true): NSColor(srgbRed: 1.000, green: 0.404, blue: 0.384, alpha: 1)
        case (.blue, false): NSColor(srgbRed: 0.090, green: 0.420, blue: 0.950, alpha: 1)
        case (.blue, true): NSColor(srgbRed: 0.400, green: 0.640, blue: 1.000, alpha: 1)
        case (.orange, false): NSColor(srgbRed: 0.930, green: 0.470, blue: 0.000, alpha: 1)
        case (.orange, true): NSColor(srgbRed: 1.000, green: 0.620, blue: 0.250, alpha: 1)
        case (.yellow, false): NSColor(srgbRed: 0.800, green: 0.600, blue: 0.000, alpha: 1)
        case (.yellow, true): NSColor(srgbRed: 1.000, green: 0.840, blue: 0.300, alpha: 1)
        // A red-leaning brown, so a lockfile reads as "machine-made", distinct from both
        // an error's red and a rename's orange.
        case (.brown, false): NSColor(srgbRed: 0.640, green: 0.330, blue: 0.200, alpha: 1)
        case (.brown, true): NSColor(srgbRed: 0.800, green: 0.500, blue: 0.360, alpha: 1)
        case (.grey, false): NSColor(srgbRed: 142 / 255, green: 142 / 255, blue: 144 / 255, alpha: 1)
        case (.grey, true): NSColor(srgbRed: 140 / 255, green: 140 / 255, blue: 140 / 255, alpha: 1)
        }
    }

    /// The hue as a SwiftUI color that follows the system appearance — for text and
    /// glyphs drawn over the app's own chrome, where no terminal background is in play.
    static func color(_ hue: Hue) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            base(hue, dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        })
    }

    static let green = color(.green)
    static let red = color(.red)
    static let blue = color(.blue)
    static let orange = color(.orange)
    static let yellow = color(.yellow)

    // MARK: Strengths

    /// How much of a hue goes into a fill, mixed into the background it sits on. Named
    /// so that two surfaces asking for "a wash" get the same one.
    enum Strength {
        /// A full-row fill that has to read at a glance: a diff's added or removed line.
        case wash
        /// A quiet row fill for a list that tags many rows at once, where a diff-strength
        /// wash on every test file would drown the names. Also the opacity of the same hue
        /// laid over a row as a translucent layer.
        case tint

        /// A dark background swallows a tint that would be plenty on a light one, so
        /// the dark side carries more of the base color.
        func amount(dark: Bool) -> CGFloat {
            switch self {
            case .wash: dark ? 0.20 : 0.12
            case .tint: dark ? 0.12 : 0.10
            }
        }
    }

    /// `hue` as a fill on `background`, mixed in rather than composited with an alpha.
    /// An alpha wash drifts in hue and strength with whatever terminal background is
    /// configured; a fixed fraction mixed in Oklab holds the same apparent strength on
    /// any background.
    static func fill(_ hue: Hue, _ strength: Strength, on background: NSColor, dark: Bool) -> NSColor {
        mix(background, base(hue, dark: dark), strength.amount(dark: dark))
    }

    /// `hue` as text on `background`, pushed toward the background's opposite until it
    /// reaches `minimumContrast`. A base tuned to read as a wash can be too faint as
    /// ink — the light green is 2.3:1 on white — and a theme background can be any
    /// color at all, so legibility is measured rather than assumed.
    static func ink(_ hue: Hue, on background: NSColor, dark: Bool, minimumContrast: CGFloat = 4.5) -> NSColor {
        legible(base(hue, dark: dark), on: background, dark: dark, minimumContrast: minimumContrast)
    }

    /// `color`, stepped toward white on a dark background or black on a light one until it
    /// contrasts `background` by `minimumContrast`. Bounded: a background that can never
    /// reach the target (a mid grey) gets the strongest step rather than a loop.
    static func legible(_ color: NSColor, on background: NSColor, dark: Bool, minimumContrast: CGFloat) -> NSColor {
        let target = dark ? NSColor.white : NSColor.black
        var ink = color
        for _ in 0..<12 where contrastRatio(ink, background) < minimumContrast {
            ink = mix(ink, target, 0.12)
        }
        return ink
    }

    /// WCAG contrast ratio between two opaque colors (1…21). A color with no sRGB
    /// components reports the neutral 1.0, so it loses every comparison.
    static func contrastRatio(_ first: NSColor, _ second: NSColor) -> CGFloat {
        guard let firstLuminance = relativeLuminance(first),
              let secondLuminance = relativeLuminance(second)
        else { return 1 }
        let lighter = max(firstLuminance, secondLuminance)
        let darker = min(firstLuminance, secondLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func relativeLuminance(_ color: NSColor) -> CGFloat? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(srgb.redComponent)
            + 0.7152 * linear(srgb.greenComponent)
            + 0.0722 * linear(srgb.blueComponent)
    }

    /// `amount` of `tint` mixed into `base`, interpolated in Oklab. Colors that cannot be
    /// read as sRGB (a pattern or catalog color with no concrete components) fall back to
    /// the base — a missing tint is better than a crash.
    static func mix(_ base: NSColor, _ tint: NSColor, _ amount: CGFloat) -> NSColor {
        guard let from = Oklab(base), let to = Oklab(tint) else { return base }
        let t = min(max(amount, 0), 1)
        return Oklab(
            lightness: from.lightness + (to.lightness - from.lightness) * t,
            a: from.a + (to.a - from.a) * t,
            b: from.b + (to.b - from.b) * t
        ).color
    }
}

/// Björn Ottosson's Oklab, enough of it to interpolate two opaque colors.
struct Oklab {
    let lightness: CGFloat
    let a: CGFloat
    let b: CGFloat

    init(lightness: CGFloat, a: CGFloat, b: CGFloat) {
        self.lightness = lightness
        self.a = a
        self.b = b
    }

    init?(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        let r = Self.linear(srgb.redComponent)
        let g = Self.linear(srgb.greenComponent)
        let b = Self.linear(srgb.blueComponent)

        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)

        lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        self.a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        self.b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    }

    var color: NSColor {
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)

        let r = Self.encode(+4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s)
        let g = Self.encode(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s)
        let blue = Self.encode(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
        return NSColor(srgbRed: r, green: g, blue: blue, alpha: 1)
    }

    private static func linear(_ component: CGFloat) -> CGFloat {
        component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }

    /// Out-of-gamut mixes are clamped rather than gamut-mapped: the inputs here are a
    /// background and a tint a fifth of the way toward it, which never strays far.
    private static func encode(_ component: CGFloat) -> CGFloat {
        let clamped = min(max(component, 0), 1)
        let encoded = clamped <= 0.0031308
            ? clamped * 12.92
            : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        return min(max(encoded, 0), 1)
    }
}
