import XCTest
@testable import fyolo

final class GhosttyUserConfigTests: XCTestCase {
    private func parsed(_ text: String) -> GhosttyUserConfig {
        var config = GhosttyUserConfig()
        config.merge(parsing: text)
        return config
    }

    func testParsesFontFamilyChainInOrder() {
        let config = parsed("""
        font-family = Berkeley Mono
        font-family = Sarasa Mono SC
        """)
        XCTAssertEqual(config.fontFamilies, ["Berkeley Mono", "Sarasa Mono SC"])
    }

    func testEmptyFontFamilyResetsChain() {
        let config = parsed("""
        font-family = Menlo
        font-family =
        font-family = JetBrains Mono
        """)
        XCTAssertEqual(config.fontFamilies, ["JetBrains Mono"])
    }

    func testStripsQuotesAndWhitespace() {
        let config = parsed("  font-family   =  \"JetBrains Mono\"  ")
        XCTAssertEqual(config.fontFamilies, ["JetBrains Mono"])
    }

    func testSkipsCommentsAndUnknownKeys() {
        let config = parsed("""
        # font-family = Commented Out
        window-decoration = false
        not a config line
        font-size = 15
        """)
        XCTAssertEqual(config.fontFamilies, [])
        XCTAssertEqual(config.fontSize, 15)
    }

    func testLastValueWinsForSingleValueKeys() {
        let config = parsed("""
        font-size = 12
        font-size = 16
        theme = Dracula
        theme = Nord
        """)
        XCTAssertEqual(config.fontSize, 16)
        XCTAssertEqual(config.themeSetting, .bare("Nord"))
    }

    func testBareThemeParsesAsBareForm() {
        XCTAssertEqual(parsed("theme = Dracula").themeSetting, .bare("Dracula"))
    }

    func testSplitThemeFormParsesPerAppearance() {
        XCTAssertEqual(
            parsed("theme = light:Solarized Light, dark:Nord").themeSetting,
            .split(light: "Solarized Light", dark: "Nord")
        )
    }

    func testExplicitSplitWithEqualNamesStaysSplit() {
        // `light:Nord,dark:Nord` is an explicit per-appearance choice, not the bare form —
        // it must inherit into both slots.
        XCTAssertEqual(
            parsed("theme = light:Nord,dark:Nord").themeSetting,
            .split(light: "Nord", dark: "Nord")
        )
    }

    func testOneSidedSplitIsRejectedLikeGhostty() {
        // Ghostty's pair form requires both slots; `theme = light:Nord` is a config
        // error there, so the previous value must stand here too.
        let config = parsed("""
        theme = Dracula
        theme = light:Nord
        """)
        XCTAssertEqual(config.themeSetting, .bare("Dracula"))
    }

    func testMalformedSplitPartRejectsWholeLine() {
        XCTAssertNil(parsed("theme = light:Nord,dark:Dracula,typo").themeSetting)
        XCTAssertNil(parsed("theme = Light:Nord,dark:Dracula").themeSetting)
    }

    func testEmptyThemeResetsToDefault() {
        let config = parsed("""
        theme = Dracula
        theme =
        """)
        XCTAssertNil(config.themeSetting)
    }

    func testQuotedSplitNamesAreUnquoted() {
        XCTAssertEqual(
            parsed("theme = light:\"Solarized Light\",dark:\"Nord\"").themeSetting,
            .split(light: "Solarized Light", dark: "Nord")
        )
    }

    func testCRLFLinesParseClean() {
        let config = parsed("font-family = Menlo\r\ntheme = Nord\r\n")
        XCTAssertEqual(config.fontFamilies, ["Menlo"])
        XCTAssertEqual(config.themeSetting, .bare("Nord"))
    }

    func testKeysAreCaseSensitiveLikeGhostty() {
        XCTAssertNil(parsed("Theme = Nord").themeSetting)
    }

    func testDuplicateFontFamiliesCollapse() {
        var config = parsed("font-family = Berkeley Mono")
        config.merge(parsing: "font-family = Berkeley Mono")
        XCTAssertEqual(config.fontFamilies, ["Berkeley Mono"])
    }

    func testMergeAcrossFilesAccumulatesFamiliesAndOverridesScalars() {
        var config = parsed("""
        font-family = Menlo
        font-size = 12
        """)
        config.merge(parsing: """
        font-family = Sarasa Mono SC
        font-size = 14
        """)
        XCTAssertEqual(config.fontFamilies, ["Menlo", "Sarasa Mono SC"])
        XCTAssertEqual(config.fontSize, 14)
    }

    func testConfigGhosttyFileIsReadAndWins() throws {
        // Ghostty ≥1.3 prefers `config.ghostty` beside the legacy `config` name and
        // loads both, the new name after — so its values must win here too.
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ghostty-config-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let xdg = home.appendingPathComponent(".config/ghostty")
        try FileManager.default.createDirectory(at: xdg, withIntermediateDirectories: true)
        try "theme = Dracula\nfont-size = 12\n".write(
            to: xdg.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "theme = Nord\n".write(
            to: xdg.appendingPathComponent("config.ghostty"), atomically: true, encoding: .utf8)

        let config = GhosttyUserConfig.load(home: home, environment: [:])
        XCTAssertEqual(config.themeSetting, .bare("Nord"))
        XCTAssertEqual(config.fontSize, 12)
    }

    func testMissingFilesYieldEmptyConfig() {
        let config = GhosttyUserConfig.load(
            home: URL(fileURLWithPath: "/nonexistent-home-for-test"),
            environment: [:]
        )
        XCTAssertTrue(config.isEmpty)
    }
}
