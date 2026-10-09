import AppKit
import XCTest
@testable import fyolo

/// Highlighting is a coloring pass: it must never change where a glyph sits. The editor seeds the
/// text storage with its line metrics up front and configures Highlightr's theme with the same
/// ones, so the async pass swaps colors onto text that is already laid out correctly. When the two
/// disagreed, opening a file painted at the font's natural line height and every line then grew by
/// the configured extra leading at once — a visible jolt a few frames in.
final class EditorLineMetricsTests: XCTestCase {
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private let lineSpacing: CGFloat = 6

    /// The fixed line box is the font's natural height plus the configured extra, and the glyphs
    /// are lifted half that to sit centered in it.
    func testLineBoxIsNaturalHeightPlusConfiguredLeading() {
        let style = HighlightedTextView.paragraphStyle(font: font, lineSpacing: lineSpacing)
        let natural = NSLayoutManager().defaultLineHeight(for: font)

        XCTAssertEqual(style.minimumLineHeight, natural + lineSpacing, accuracy: 0.001)
        XCTAssertEqual(style.maximumLineHeight, style.minimumLineHeight, accuracy: 0.001)
        XCTAssertEqual(HighlightedTextView.baselineOffset(lineSpacing: lineSpacing), lineSpacing / 2,
                       accuracy: 0.001)
    }

    /// The invariant that keeps the editor still: what the highlighter stamps on every token has
    /// the same metrics as what the storage was seeded with, so the pass moves nothing.
    func testHighlighterCarriesTheSameMetricsTheStorageIsSeededWith() throws {
        let highlightr = try XCTUnwrap(Highlightr(), "no highlighter available in this environment")
        let style = HighlightedTextView.paragraphStyle(font: font, lineSpacing: lineSpacing)
        let offset = HighlightedTextView.baselineOffset(lineSpacing: lineSpacing)
        highlightr.theme.setCodeFont(font)
        highlightr.theme.codeParagraphStyle = style
        highlightr.theme.codeBaselineOffset = offset

        let highlighted = try XCTUnwrap(highlightr.highlight("let answer = 42", as: "swift"))
        var applied: [NSAttributedString.Key: Any] = [:]
        highlighted.enumerateAttributes(in: NSRange(location: 0, length: highlighted.length)) { attrs, _, stop in
            applied = attrs
            stop.pointee = true
        }

        XCTAssertEqual(applied[.paragraphStyle] as? NSParagraphStyle, style)
        XCTAssertEqual(applied[.baselineOffset] as? CGFloat, offset)
        XCTAssertEqual((applied[.font] as? NSFont)?.pointSize, font.pointSize)
    }

    /// A file hljs has no grammar for gets no highlight pass at all, so its metrics can only come
    /// from the seed — the case that used to render at the wrong line height forever.
    func testUnhighlightedTextKeepsItsSeededMetrics() {
        let storage = CodeAttributedString(highlightr: nil)
        let style = HighlightedTextView.paragraphStyle(font: font, lineSpacing: lineSpacing)
        storage.setAttributedString(NSAttributedString(string: "plain text\nsecond line", attributes: [
            .font: font,
            .paragraphStyle: style,
            .baselineOffset: HighlightedTextView.baselineOffset(lineSpacing: lineSpacing),
        ]))

        let attrs = storage.attributes(at: 0, effectiveRange: nil)
        XCTAssertEqual(attrs[.paragraphStyle] as? NSParagraphStyle, style)
        XCTAssertEqual(attrs[.baselineOffset] as? CGFloat, lineSpacing / 2)
    }
}
