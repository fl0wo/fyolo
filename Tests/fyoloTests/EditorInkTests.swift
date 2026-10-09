import AppKit
import SwiftUI
import XCTest
@testable import fyolo

/// The editor's base ink: what a glyph is drawn in *before* — or entirely without — a syntax-
/// highlighting pass. Only the highlighter's own per-token rules ever colored this text, so a
/// buffer that gets no pass at all (no grammar for the extension, or past the size limit) fell
/// through to AppKit's built-in black. On the dark terminal background the editor paints that is
/// a 1.14:1 contrast ratio — a `LICENSE` read as an empty file (#662).
///
/// The property that keeps it fixed: the ink is opaque and comes from the same theme as the
/// background it lands on, rather than from a system color that resolves the wrong side.
@MainActor
final class EditorInkTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editor-ink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "editor-ink-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func makeSettings() -> AppSettings {
        AppSettings(
            defaults: defaults,
            settingsStore: SettingsStore(
                defaults: defaults,
                fileURL: directory.appendingPathComponent("settings.json"),
                domainName: suiteName))
    }

    // MARK: - The ink itself

    /// The reported case: dark appearance, no theme selected, so the ink takes its fallback. Light
    /// ink on the default dark canvas — the failure was ink that went the other way.
    func testDarkFallbackInkIsLight() throws {
        let ink = makeSettings().editorInk(for: .dark)
        XCTAssertGreaterThan(
            try relativeLuminance(ink), 0.5,
            "dark-appearance editor ink must be light; AppKit's built-in black text is what #662 shipped")
    }

    func testLightFallbackInkIsDark() throws {
        let ink = makeSettings().editorInk(for: .light)
        XCTAssertLessThan(
            try relativeLuminance(ink), 0.5,
            "light-appearance editor ink must be dark")
    }

    /// The real check: whatever the ink is, it has to be readable on the background it is drawn
    /// on. Both colors resolve through their own appearance slot, the way the window does.
    func testFallbackInkClearsAAOnItsOwnCanvas() throws {
        let settings = makeSettings()
        for scheme in [ColorScheme.dark, ColorScheme.light] {
            let ink = resolved(settings.editorInk(for: scheme), as: scheme)
            let background = resolved(settings.terminalBackgroundColor, as: scheme)
            XCTAssertGreaterThanOrEqual(
                contrastRatio(ink, background), 4.5,
                "plain editor text must clear WCAG AA on the \(scheme) canvas it is drawn on")
        }
    }

    /// The theme path: a picked theme's own foreground, so unhighlighted text sits in the palette
    /// the rest of the chrome is drawn from.
    ///
    /// Note the assertion is identity, not a contrast floor. Some bundled themes really do pair a
    /// foreground close to their own background (Darkermatrix is 1.89:1) — that is the theme's
    /// choice, and plain text has to match how that theme renders plain text in the terminal.
    /// Second-guessing it here would make the editor disagree with the pane behind it.
    func testInkFollowsTheSelectedThemeForeground() throws {
        let settings = makeSettings()
        let name = try XCTUnwrap(
            ThemeLibrary.builtInNames(dark: true).first, "no bundled dark theme to test with")
        let definition = try XCTUnwrap(ThemeLibrary.theme(named: name))
        settings.darkThemeName = name

        let ink = try XCTUnwrap(settings.editorInk(for: .dark).usingColorSpace(.sRGB))
        let foreground = try XCTUnwrap(srgb(hex: definition.foreground))
        XCTAssertEqual(ink.redComponent, foreground.redComponent, accuracy: 0.001)
        XCTAssertEqual(ink.greenComponent, foreground.greenComponent, accuracy: 0.001)
        XCTAssertEqual(ink.blueComponent, foreground.blueComponent, accuracy: 0.001)
    }

    /// Opacity is half the fix: a translucent ink lets the background through and reads as
    /// grey-on-grey however bright its components are.
    func testInkIsOpaque() {
        let settings = makeSettings()
        for scheme in [ColorScheme.dark, ColorScheme.light] {
            XCTAssertEqual(settings.editorInk(for: scheme).alphaComponent, 1, accuracy: 0.001,
                           "base text ink must be opaque — the \(scheme) fallback is translucent")
        }
        settings.darkThemeName = ThemeLibrary.builtInNames(dark: true).first ?? ""
        XCTAssertEqual(settings.editorInk(for: .dark).alphaComponent, 1, accuracy: 0.001,
                       "base text ink must be opaque — the themed path is translucent")
    }

    /// The slots are independent, and the ink resolves per appearance — the dark side must not be
    /// answered with the light theme's foreground.
    func testTheTwoAppearancesResolveTheirOwnSlot() throws {
        let settings = makeSettings()
        let dark = try XCTUnwrap(ThemeLibrary.builtInNames(dark: true).first)
        let light = try XCTUnwrap(ThemeLibrary.builtInNames(dark: false).first)
        settings.darkThemeName = dark
        settings.lightThemeName = light

        let darkInk = try XCTUnwrap(settings.editorInk(for: .dark).usingColorSpace(.sRGB))
        let lightInk = try XCTUnwrap(settings.editorInk(for: .light).usingColorSpace(.sRGB))

        XCTAssertGreaterThan(
            try relativeLuminance(darkInk), try relativeLuminance(lightInk),
            "the dark slot's ink must be the brighter of the two — the slots were crossed")
    }

    // MARK: - What the text storage actually carries

    /// The end of the chain: the attributes the storage is seeded with. `foregroundColor` was the
    /// missing key — everything else in this list is layout, and a buffer that never gets a
    /// highlight pass draws in AppKit's black without it.
    func testSeededAttributesCarryTheInk() {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let ink = NSColor(srgbRed: 0.9, green: 0.9, blue: 0.9, alpha: 1)
        let storage = CodeAttributedString(highlightr: nil)
        storage.setAttributedString(NSAttributedString(
            string: "MIT License",
            attributes: [
                .font: font,
                .foregroundColor: ink,
                .paragraphStyle: HighlightedTextView.paragraphStyle(font: font, lineSpacing: 6),
                .baselineOffset: HighlightedTextView.baselineOffset(lineSpacing: 6),
            ]))

        let attributes = storage.attributes(at: 0, effectiveRange: nil)
        let carried = attributes[.foregroundColor] as? NSColor
        XCTAssertEqual(carried, ink)
        XCTAssertEqual(carried?.alphaComponent, 1)
    }

    // MARK: - Why the ink is never written document-wide

    /// `NSTextView.textColor` is the one way *not* to state the ink, and the reason is not obvious
    /// enough to leave to a comment: the setter is whole-document, and the getter does not report
    /// what was last assigned — it answers with the **first character's** foreground color. So the
    /// `if textView.textColor != ink` shape that works for `font` cannot work here. On any buffer
    /// the highlighter has been through, the first character is a token with a color of its own,
    /// the guard never holds, and the write flattens every syntax color in the document. Nothing
    /// puts them back either: `CodeAttributedString.processEditing` re-highlights on
    /// `.editedCharacters` only, and an attribute-only write edits no characters.
    ///
    /// `apply(to:)` states the ink through the typing attributes instead, and leaves text already
    /// in the storage to the `baseAttributes` an appearance switch re-applies.
    func testDocumentWideInkWriteFlattensTheSyntaxColors() throws {
        let highlightr = try XCTUnwrap(Highlightr())
        _ = highlightr.setTheme(to: "xcode-dark")
        let highlighted = try XCTUnwrap(
            highlightr.highlight("import Foundation\nlet x = 1\n", as: "swift"))

        let storage = CodeAttributedString(highlightr: highlightr)
        storage.language = "swift"
        storage.setAttributedString(highlighted)
        let container = NSTextContainer(size: NSSize(width: 400, height: 400))
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)

        func distinctColors() -> Set<String> {
            var seen = Set<String>()
            storage.enumerateAttribute(
                .foregroundColor, in: NSRange(location: 0, length: storage.length)
            ) { value, _, _ in
                guard let color = (value as? NSColor)?.usingColorSpace(.sRGB) else { return }
                seen.insert(String(
                    format: "%.3f,%.3f,%.3f",
                    color.redComponent, color.greenComponent, color.blueComponent))
            }
            return seen
        }

        let colored = distinctColors()
        XCTAssertGreaterThan(colored.count, 1, "the sample did not highlight — nothing to protect")

        let ink = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        XCTAssertNotEqual(
            textView.textColor, ink,
            "the getter reports the first token's color, so a change-gated write would fire here")

        textView.typingAttributes[.foregroundColor] = ink
        XCTAssertEqual(
            distinctColors(), colored,
            "stating the ink through the typing attributes must leave the document alone")

        textView.textColor = ink
        XCTAssertEqual(
            distinctColors().count, 1,
            "a document-wide write is destructive — this is what the editor must not do")
    }

    // MARK: - Helpers

    /// Resolve a dynamic color through the appearance it is pinned to, rather than letting it fall
    /// to whatever `NSAppearance.current` happens to be — the trap `App.swift` documents for the
    /// same property. `performAsCurrentDrawingAppearance` returns Void, so the result is carried
    /// out through a capture, the way the app's own resolvers do it.
    private func resolved(_ color: NSColor, as scheme: ColorScheme) -> NSColor {
        let name: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
        guard let appearance = NSAppearance(named: name) else { return color }
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }

    private func relativeLuminance(_ color: NSColor) throws -> Double {
        let srgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
        func linear(_ component: CGFloat) -> Double {
            let value = Double(component)
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(srgb.redComponent)
            + 0.7152 * linear(srgb.greenComponent)
            + 0.0722 * linear(srgb.blueComponent)
    }

    private func contrastRatio(_ first: NSColor, _ second: NSColor) -> Double {
        guard let a = try? relativeLuminance(first), let b = try? relativeLuminance(second) else {
            return 1
        }
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// `GhosttyThemeDefinition` stores its colors as bare six-digit hex.
    private func srgb(hex: String) -> NSColor? {
        let raw = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1)
    }
}
