import XCTest
import GhosttyTerminal
import GhosttyTheme
import SwiftUI
import FyoloShared
@testable import fyolo

/// The theme library's load-bearing guarantees: a theme written to disk reads back
/// as the same theme, the built-in set stays the curated list it claims to be —
/// every name resolvable, the brightness split intact, no two rows in a slot close
/// enough to read as the same theme — and resolution reaches every name a slot can
/// end up holding, including one inherited from a Ghostty config.
@MainActor
final class ThemeLibraryTests: XCTestCase {
    // MARK: - write / parse

    func testWriteRoundTripsThroughParse() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("theme-library-round-trip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let definition = GhosttyThemeDefinition(
            name: "Round Trip",
            background: "1e1e2e",
            foreground: "cdd6f4",
            cursorColor: "f5e0dc",
            cursorText: "11111b",
            selectionBackground: "585b70",
            selectionForeground: "cdd6f4",
            palette: [0: "45475a", 1: "f38ba8", 7: "bac2de", 15: "a6adc8"]
        )
        try ThemeLibrary.write(definition, into: folder)

        let url = folder.appendingPathComponent(definition.name, isDirectory: false)
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(ThemeLibrary.parse(name: definition.name, contents: contents), definition)
    }

    /// A theme with no optional colors at all must survive the trip too — the
    /// serializer has to omit those keys rather than write empty values that parse
    /// back as blank hex.
    func testWriteRoundTripsAThemeWithoutOptionalColors() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("theme-library-minimal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let definition = GhosttyThemeDefinition(
            name: "Bare", background: "ffffff", foreground: "000000")
        try ThemeLibrary.write(definition, into: folder)

        let contents = try String(
            contentsOf: folder.appendingPathComponent(definition.name, isDirectory: false),
            encoding: .utf8)
        XCTAssertEqual(ThemeLibrary.parse(name: definition.name, contents: contents), definition)
    }

    /// Every built-in has to survive being written and read back, not just a
    /// hand-picked one — that trip is what **Duplicate to Themes Folder** does.
    func testEveryBuiltInThemeRoundTrips() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("theme-library-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        for definition in ThemeLibrary.builtInThemes {
            let url = try ThemeLibrary.write(definition, into: folder)
            let contents = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(
                ThemeLibrary.parse(name: definition.name, contents: contents), definition,
                definition.name)
        }
    }

    // MARK: - Built-ins

    func testEveryBuiltInNameResolves() {
        let unresolved = BuiltInThemes.names.filter { GhosttyThemeCatalog.theme(named: $0) == nil }
        XCTAssertEqual(unresolved, [], "built-in names missing from the pinned catalog")
        // The compactMap that drops stale entries must be dropping nothing today; a
        // name silently disappearing from the picker is what it would look like.
        XCTAssertEqual(ThemeLibrary.builtInThemes.map(\.name), BuiltInThemes.names)
    }

    /// Derived from each theme's own background luminance, never a hand-kept
    /// per-name assignment — that is the whole point of `isDark` deciding the slot.
    /// The tally lives here and nowhere else, so growing the list is one number to
    /// update rather than a sweep through prose. It is a tripwire, not a target:
    /// what it catches is a name added or lost without anyone meaning to.
    func testBuiltInsSplitByBackgroundLuminance() {
        let definitions = ThemeLibrary.builtInThemes
        XCTAssertEqual(definitions.count, 69)
        XCTAssertEqual(definitions.filter(\.isDark).count, 47)
        XCTAssertEqual(definitions.filter { !$0.isDark }.count, 22)
    }

    /// The curation rule that keeps the list free of near-duplicates: within a
    /// slot, no two themes of different families sit closer than ΔE 11 on the
    /// weighted Lab metric the list was built with. Rejected pairs measure far
    /// below it (TokyoNight Night vs Storm 2.6), so a scheme arriving a second
    /// time under another name fails here.
    ///
    /// The floor was 12 until Catppuccin Frappé joined: it sits 11.3 from Nord —
    /// two blue-greys, `303446` against `2e3440` — and is now the list's tightest
    /// pair, under the 12.1 of Kanagawa Dragon vs Melange Dark that set the old
    /// line. Admitting a flavor someone came looking for is worth 0.7 of ΔE; a
    /// third theme in that neighbourhood would not be.
    ///
    /// Flavors of one family are compared only for the split and the resolve.
    /// Putting `Catppuccin Frappe` beside `Catppuccin Mocha` is a decision someone
    /// made on purpose, and no ΔE would have told them otherwise.
    func testNoTwoBuiltInsInASlotReadAsTheSameTheme() throws {
        for dark in [true, false] {
            let definitions = ThemeLibrary.builtInThemes.filter { $0.isDark == dark }
            for first in 0..<definitions.count {
                for second in (first + 1)..<definitions.count {
                    guard !sameFamily(definitions[first].name, definitions[second].name) else { continue }
                    let distance = try weightedDistance(definitions[first], definitions[second])
                    XCTAssertGreaterThanOrEqual(
                        distance, 11,
                        "\(definitions[first].name) and \(definitions[second].name) read as one theme")
                }
            }
        }
    }

    /// Themes of one scheme family, which every catalog spells as a shared first
    /// word: Catppuccin Mocha/Macchiato/Frappe, Kanagawa Wave/Dragon.
    private func sameFamily(_ first: String, _ second: String) -> Bool {
        first.split(separator: " ").first == second.split(separator: " ").first
    }

    // MARK: - Chrome

    /// Adding a theme to the list also puts it behind the sidebar and the window,
    /// so every built-in has to derive chrome — a name that paints the terminal
    /// but drops the chrome back to the system appearance is a half-applied theme,
    /// which is what a missing background or foreground would produce.
    func testEveryBuiltInDerivesChrome() throws {
        for definition in ThemeLibrary.builtInThemes {
            let chrome = try XCTUnwrap(ChromeTheme(definition), definition.name)
            XCTAssertEqual(chrome.isDark, definition.isDark, definition.name)
        }
    }

    // MARK: - Resolution

    /// Every built-in of a slot's brightness is offered by that slot, and none of
    /// the other slot's leaks in. Asserted as a subset because the machine running
    /// the tests may also have its own theme files, which belong in the list too.
    func testEverySlotOffersItsOwnBuiltIns() {
        for dark in [true, false] {
            let offered = Set(ThemeLibrary.selectableNames(dark: dark))
            for definition in ThemeLibrary.builtInThemes {
                XCTAssertEqual(
                    offered.contains(definition.name), definition.isDark == dark,
                    "\(definition.name) in the \(dark ? "dark" : "light") slot")
            }
        }
    }

    /// A Ghostty config may name any of the bundled schemes, not just the curated
    /// ones, and fyolo writes that name straight into a slot. Resolution has to
    /// reach it — otherwise the window paints the default while the setting says
    /// otherwise.
    func testResolutionReachesPastTheBuiltInsIntoTheCatalog() throws {
        let inherited = try XCTUnwrap(firstCatalogThemeOutsideTheBuiltIns(dark: true))
        XCTAssertEqual(ThemeLibrary.theme(named: inherited.name), inherited)
    }

    /// …and it is listed, not just resolvable. A name that paints the window while
    /// sitting off the list that controls it is the ghost selection this library is
    /// built to make impossible.
    func testAnInheritedSelectionIsListedInItsSlot() throws {
        let inherited = try XCTUnwrap(firstCatalogThemeOutsideTheBuiltIns(dark: true))
        XCTAssertTrue(
            ThemeLibrary.selectableNames(dark: true, selection: inherited.name)
                .contains(inherited.name))
        // The wider catalog is reached for the selection only — it is not a source
        // the list draws from, or the picker would be 485 rows deep.
        XCTAssertFalse(ThemeLibrary.selectableNames(dark: true).contains(inherited.name))
    }

    /// A selection of the wrong brightness is not smuggled into the slot by the
    /// inherited-name path.
    func testAnInheritedSelectionOfTheWrongBrightnessIsNotListed() throws {
        let inherited = try XCTUnwrap(firstCatalogThemeOutsideTheBuiltIns(dark: false))
        XCTAssertFalse(
            ThemeLibrary.selectableNames(dark: true, selection: inherited.name)
                .contains(inherited.name))
    }

    /// A Ghostty config spells theme names its own way, and the slot it feeds is
    /// written from the catalog's spelling — so `theme = catppuccin-frappe` has to
    /// land on `Catppuccin Frappe` rather than on fyolo's default. An unknown
    /// name resolves to nothing, which is what leaves that slot at the default
    /// instead of guessing at a theme file fyolo cannot render.
    func testAGhosttySpellingResolvesToTheCatalogName() {
        for spelling in ["catppuccin-frappe", "Catppuccin Frappe", "CATPPUCCIN FRAPPE", "catppuccinfrappe"] {
            XCTAssertEqual(
                ThemeLibrary.catalogTheme(matching: spelling)?.name, "Catppuccin Frappe", spelling)
        }
        XCTAssertNil(ThemeLibrary.catalogTheme(matching: "a theme nobody shipped"))
    }

    private func firstCatalogThemeOutsideTheBuiltIns(dark: Bool) -> GhosttyThemeDefinition? {
        let builtIn = Set(ThemeLibrary.builtInThemes.map(\.name))
        let userOwned = Set(ThemeLibrary.userThemeNames)
        return GhosttyThemeCatalog.allThemes.first {
            $0.isDark == dark && !builtIn.contains($0.name) && !userOwned.contains($0.name)
        }
    }

    // MARK: - Light contrast

    /// Issue #426: the light default inherited Alabaster's ANSI white and bright
    /// white — #F7F7F7, the color Alabaster also uses for paper — so every line an
    /// agent printed as "white" landed at 1.07:1 on the canvas and disappeared. Both
    /// slots have to stay ink.
    func testLightDefaultRendersAnsiWhiteAsInk() throws {
        let config = FyoloStore.lightDefaultTheme.rendered
        let background = try XCTUnwrap(lastValue(of: "background", in: config))
        for slot in [7, 15] {
            let color = try XCTUnwrap(lastPaletteValue(slot, in: config))
            let ratio = contrast(color, background)
            XCTAssertGreaterThan(ratio, 3, "ANSI \(slot) reads at \(ratio):1 against \(background)")
        }
    }

    /// The palette above only covers the default; the floor is what covers the other
    /// light themes, the ones a user drops into the Themes folder, and a palette an
    /// agent rewrites at runtime over OSC 4. It has to ride on every light theme and
    /// on none of the dark ones — a dark theme's ANSI black sits on its background
    /// on purpose.
    func testTheContrastFloorFollowsThemeBrightness() throws {
        for definition in ThemeLibrary.builtInThemes {
            let rendered = try XCTUnwrap(FyoloStore.themeConfiguration(named: definition.name)).rendered
            let floor = lastValue(of: "minimum-contrast", in: rendered)
            if definition.isDark {
                XCTAssertNil(floor, definition.name)
            } else {
                XCTAssertEqual(floor.flatMap(Double.init), FyoloStore.lightContrastFloor, definition.name)
            }
        }
        XCTAssertEqual(
            lastValue(of: "minimum-contrast", in: FyoloStore.lightDefaultTheme.rendered)
                .flatMap(Double.init),
            FyoloStore.lightContrastFloor
        )
    }

    /// Both halves of the fix are keys libghostty has to accept: a rejected config
    /// does not fall back to the previous colors, it leaves the whole theme
    /// unapplied. So build the real thing and let ghostty parse it.
    func testTheLightDefaultIsAConfigGhosttyAccepts() {
        let state = TerminalViewState(
            theme: TerminalTheme(light: FyoloStore.lightDefaultTheme, dark: .afterglow))
        XCTAssertNil(state.controller.lastConfigurationIssue)
        // `effectiveColorScheme` starts light, so this is the slot under test.
        XCTAssertTrue(state.renderedConfig.contains("palette = 7=#4D4D4D"), state.renderedConfig)
        XCTAssertTrue(state.renderedConfig.contains("palette = 15=#262626"), state.renderedConfig)
        XCTAssertTrue(state.renderedConfig.contains("minimum-contrast = 1.5"), state.renderedConfig)
    }

    /// A floor above 2 would be worse than the bug: libghostty snaps a failing
    /// foreground to pure black or white rather than nudging it, and the bundled
    /// light palettes put their legible-but-dim greys and yellows just above 2:1.
    func testTheContrastFloorStaysBelowTheFlatteningPoint() {
        XCTAssertGreaterThan(FyoloStore.lightContrastFloor, 1)
        XCTAssertLessThanOrEqual(FyoloStore.lightContrastFloor, 1.75)
    }

    /// `rendered` is append-only, so an override lands as a second line for the same
    /// key — the way Ghostty itself resolves a repeated key, last one wins.
    private func lastValue(of key: String, in config: String) -> String? {
        config.split(separator: "\n")
            .last { $0.hasPrefix("\(key) = ") }
            .map { String($0.dropFirst(key.count + 3)) }
    }

    private func lastPaletteValue(_ slot: Int, in config: String) -> String? {
        let prefix = "palette = \(slot)="
        return config.split(separator: "\n")
            .last { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    private func contrast(_ first: String, _ second: String) -> Double {
        guard let first = Color(hex: first), let second = Color(hex: second) else { return 1 }
        return ChromeTheme.contrastRatio(first, second)
    }

    // MARK: - Distinctness metric

    /// Weighted mean CIE Lab distance between two themes: the background dominates
    /// what a theme looks like (×2.5), the body text follows (×1.2), and the six
    /// ANSI colors a user recognizes a scheme by carry the rest (×0.7 each).
    private func weightedDistance(
        _ first: GhosttyThemeDefinition, _ second: GhosttyThemeDefinition
    ) throws -> Double {
        var total = 0.0
        var weight = 0.0
        func accumulate(_ firstHex: String, _ secondHex: String, _ factor: Double) throws {
            let a = try XCTUnwrap(lab(firstHex), firstHex)
            let b = try XCTUnwrap(lab(secondHex), secondHex)
            let distance = ((a.0 - b.0) * (a.0 - b.0)
                + (a.1 - b.1) * (a.1 - b.1)
                + (a.2 - b.2) * (a.2 - b.2)).squareRoot()
            total += factor * distance
            weight += factor
        }
        try accumulate(first.background, second.background, 2.5)
        try accumulate(first.foreground, second.foreground, 1.2)
        for slot in 1...6 {
            guard let firstColor = first.palette[slot], let secondColor = second.palette[slot] else { continue }
            try accumulate(firstColor, secondColor, 0.7)
        }
        guard weight > 0 else { return 0 }
        return total / weight
    }

    /// sRGB hex → CIE Lab under D65, the space the ΔE above is measured in.
    private func lab(_ hex: String) -> (Double, Double, Double)? {
        let raw = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else { return nil }
        func linear(_ channel: UInt32) -> Double {
            let component = Double(channel) / 255
            return component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        let red = linear((value >> 16) & 0xff)
        let green = linear((value >> 8) & 0xff)
        let blue = linear(value & 0xff)
        let x = (red * 0.4124564 + green * 0.3575761 + blue * 0.1804375) / 0.95047
        let y = red * 0.2126729 + green * 0.7151522 + blue * 0.0721750
        let z = (red * 0.0193339 + green * 0.1191920 + blue * 0.9503041) / 1.08883
        func pivot(_ component: Double) -> Double {
            component > 216.0 / 24389.0 ? pow(component, 1.0 / 3.0) : (841.0 / 108.0) * component + 4.0 / 29.0
        }
        let fx = pivot(x), fy = pivot(y), fz = pivot(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }
}
