import UIKit
import GhosttyTheme

/// Chrome colors borrowed from the terminal theme the user picked — the phone's
/// counterpart of the Mac's `ChromeTheme`, and for the same reason: fyolo keeps
/// a single source of color truth rather than a second palette that drifts from
/// the terminal's. The inbox, project pages, settings cards, and the terminal
/// surface all read as one canvas instead of a themed terminal floating in stark
/// system color.
///
/// Every color resolves the light/dark theme name per the trait's appearance, so
/// a system light↔dark flip re-resolves it for free. A theme *name* change does
/// not flip traits, so callers must re-assign — see `installThemeBackdrop` and
/// `ThemedTableViewController`.
enum ThemeChrome {
    /// The page backdrop: the theme's own background.
    static var background: UIColor {
        themed { theme, dark in background(theme, dark) }
    }

    /// The grouped-cell fill: one step off the backdrop, lighter over a dark
    /// theme and darker over a light one. Deriving the step rather than naming a
    /// second color is what keeps every theme in the catalog legible — a light
    /// theme whose background is already near-white leaves a white card nothing
    /// to sit on, which is exactly how system cells look wrong here.
    static var card: UIColor {
        themed { theme, dark in
            background(theme, dark).blended(with: dark ? .white : .black, amount: dark ? 0.07 : 0.05)
        }
    }

    /// Primary chrome text.
    static var ink: UIColor {
        themed { theme, _ in foreground(theme) }
    }

    /// Muted chrome text (row values, section headers and footers). One alpha
    /// for both brightnesses is too thin over a light card, so the light side is
    /// lifted — the same split the Mac's `secondaryForeground` measured out.
    static var secondaryInk: UIColor {
        themed { theme, dark in foreground(theme).withAlphaComponent(dark ? 0.6 : 0.75) }
    }

    /// Hairlines between rows: overlay ink, never the theme's own foreground. A
    /// grey or tinted foreground sinks into the background at any alpha, so
    /// contrast has to come from the background's darkness — the lesson the
    /// Mac's `ChromeTheme.overlayInk` records.
    static var separator: UIColor {
        themed { _, dark in (dark ? UIColor.white : .black).withAlphaComponent(dark ? 0.14 : 0.1) }
    }

    /// The selection mark's color — the theme's blue, the same derivation the
    /// Mac's chrome accent uses. A theme whose ANSI blue is deep enough to
    /// vanish on its own background (Melange Light, Cobalt2) must use its bright
    /// blue instead, so take whichever of palette 4 and 12 contrasts the
    /// background more, then fall through the quieter selection grey to the
    /// foreground so it always resolves.
    static var accent: UIColor {
        themed { theme, dark in
            guard let theme else { return .tintColor }
            let background = background(theme, dark)
            let blues = [theme.palette[4], theme.palette[12]]
                .compactMap { $0 }
                .compactMap { UIColor(ghosttyHex: $0) }
            return blues.max { contrastRatio($0, background) < contrastRatio($1, background) }
                ?? theme.selectionBackground.flatMap { UIColor(ghosttyHex: $0) }
                ?? foreground(theme)
        }
    }

    /// WCAG contrast ratio between two opaque colors (1…21). Colors that can't
    /// be resolved into RGB report the neutral 1.0 rather than trapping, which
    /// makes them lose every comparison instead of winning one by accident.
    private static func contrastRatio(_ first: UIColor, _ second: UIColor) -> CGFloat {
        guard let firstLuminance = relativeLuminance(first),
              let secondLuminance = relativeLuminance(second)
        else { return 1 }
        return (max(firstLuminance, secondLuminance) + 0.05)
            / (min(firstLuminance, secondLuminance) + 0.05)
    }

    private static func relativeLuminance(_ color: UIColor) -> CGFloat? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    private static func background(_ theme: GhosttyThemeDefinition?, _ dark: Bool) -> UIColor {
        theme.flatMap { UIColor(ghosttyHex: $0.background) } ?? (dark ? .black : .white)
    }

    private static func foreground(_ theme: GhosttyThemeDefinition?) -> UIColor {
        theme.flatMap { UIColor(ghosttyHex: $0.foreground) } ?? .label
    }

    private static func themed(
        _ resolve: @escaping (GhosttyThemeDefinition?, Bool) -> UIColor
    ) -> UIColor {
        UIColor { traits in
            let settings = MobileSettings.shared
            let dark = traits.userInterfaceStyle == .dark
            let name = dark ? settings.darkThemeName : settings.lightThemeName
            return resolve(GhosttyThemeCatalog.theme(named: name), dark)
        }
    }
}

extension UIViewController {
    /// Paints this chrome page with the terminal theme background and returns an
    /// observer token that re-asserts it whenever settings change. Re-assigning
    /// is required because a theme-*name* change (light→a different light theme)
    /// doesn't flip the trait collection, so UIKit keeps serving the stale
    /// resolved color until the dynamic `UIColor` is set again. Store the token
    /// and remove it in `deinit`, matching the other observers in these VCs.
    func installThemeBackdrop() -> NSObjectProtocol {
        view.backgroundColor = ThemeChrome.background
        return NotificationCenter.default.addObserver(
            forName: MobileSettings.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.view.backgroundColor = ThemeChrome.background
        }
    }
}

/// A grouped table page painted in the terminal theme: the backdrop, the cards,
/// the ink, and the hairlines all come from `ThemeChrome`, so picking a theme
/// restyles it the way it restyles the terminal. Subclasses build their cells as
/// usual and hand each one to `applyTheme(to:)` before their own per-row colors
/// (a destructive row's red, a status value's green) go on top.
class ThemedTableViewController: UITableViewController {
    private var themeObserver: NSObjectProtocol?

    deinit {
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        paint()
        themeObserver = NotificationCenter.default.addObserver(
            forName: MobileSettings.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.paint()
            // The cells carry resolved colors of their own, and a theme-name
            // change doesn't flip traits to re-resolve them: rebuild the rows.
            self?.tableView.reloadData()
        }
    }

    private func paint() {
        view.backgroundColor = ThemeChrome.background
        tableView.separatorColor = ThemeChrome.separator
    }

    func applyTheme(to cell: UITableViewCell) {
        // In a grouped table the cell's own fill is what the section's rounded
        // card draws, so this is the card color, corners included.
        cell.backgroundColor = ThemeChrome.card
        cell.textLabel?.textColor = ThemeChrome.ink
        cell.detailTextLabel?.textColor = ThemeChrome.secondaryInk
        cell.imageView?.tintColor = ThemeChrome.ink
    }

    override func tableView(
        _ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int
    ) {
        (view as? UITableViewHeaderFooterView)?.textLabel?.textColor = ThemeChrome.secondaryInk
    }

    override func tableView(
        _ tableView: UITableView, willDisplayFooterView view: UIView, forSection section: Int
    ) {
        (view as? UITableViewHeaderFooterView)?.textLabel?.textColor = ThemeChrome.secondaryInk
    }
}

private extension UIColor {
    /// Mixes toward `other` by `amount` — the UIKit twin of the Mac chrome's
    /// `Color.blended(with:amount:)`. Colors that don't resolve into RGBA (a
    /// pattern or an unresolved dynamic color) come back unchanged rather than
    /// mixing against zeroes.
    func blended(with other: UIColor, amount: CGFloat) -> UIColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        var otherRed: CGFloat = 0, otherGreen: CGFloat = 0, otherBlue: CGFloat = 0
        var otherAlpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha),
              other.getRed(&otherRed, green: &otherGreen, blue: &otherBlue, alpha: &otherAlpha)
        else { return self }
        let mix = min(max(amount, 0), 1)
        return UIColor(
            red: red + (otherRed - red) * mix,
            green: green + (otherGreen - green) * mix,
            blue: blue + (otherBlue - blue) * mix,
            alpha: alpha + (otherAlpha - alpha) * mix
        )
    }
}
