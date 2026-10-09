import XCTest
@testable import fyolo

/// A PDF has no paragraphs, only typeset lines, so a selection comes back broken at every
/// line ending and hyphenated at every margin. Pasted into an agent's prompt that reads as
/// a column of fragments — which is the whole reason quoting a paper into a terminal is
/// miserable. These are the joins that have to be right.
final class PDFSelectionTextTests: XCTestCase {
    func testWrappedLinesRejoinIntoOneParagraph() {
        let raw = """
        The terminal is the interface, and the session
        lives on the box rather than in the
        connection.
        """
        XCTAssertEqual(
            PDFSelectionText.unwrapped(raw),
            "The terminal is the interface, and the session lives on the box rather than in the connection.")
    }

    func testHyphenAtTheMarginIsHealed() {
        XCTAssertEqual(PDFSelectionText.unwrapped("inter-\npretation"), "interpretation")
    }

    /// A hyphen the author typed is not a line break: the next line starting with a capital
    /// or a digit is the tell.
    func testAuthoredHyphenSurvives() {
        XCTAssertEqual(PDFSelectionText.unwrapped("Anti-\nBayesian"), "Anti- Bayesian")
        XCTAssertEqual(PDFSelectionText.unwrapped("COVID-\n19 data"), "COVID- 19 data")
    }

    func testBlankLineKeepsAParagraphBreak() {
        let raw = """
        First paragraph
        continues here.

        Second paragraph.
        """
        XCTAssertEqual(
            PDFSelectionText.unwrapped(raw),
            "First paragraph continues here.\n\nSecond paragraph.")
    }

    /// A list is written that way; rejoining it would turn three items into one sentence.
    func testListItemsKeepTheirOwnLines() {
        let raw = """
        Three rules:
        - never embed SSH
        - one protocol
        2. single writer
        """
        XCTAssertEqual(
            PDFSelectionText.unwrapped(raw),
            "Three rules:\n\n- never embed SSH\n- one protocol\n2. single writer")
    }

    /// A dash in front of a number is a sign, not a bullet.
    func testNegativeNumberIsNotABullet() {
        XCTAssertEqual(PDFSelectionText.unwrapped("gain of\n-3.4 dB"), "gain of -3.4 dB")
    }

    func testExtractionSpacingIsCollapsed() {
        XCTAssertEqual(PDFSelectionText.unwrapped("one    two\n   three  "), "one two three")
    }

    /// Two renderings of one sentence — different line breaks, a hyphen in a different
    /// place — have to compare equal, or a mark can never recognise its own words in a
    /// re-typeset page.
    func testSquashedIgnoresLayout() {
        XCTAssertEqual(
            PDFSelectionText.squashed("The session lives on the\nbox, not in the con-\nnection."),
            PDFSelectionText.squashed("The session lives\non the box, not in\nthe connection."))
        XCTAssertNotEqual(PDFSelectionText.squashed("the process"),
                          PDFSelectionText.squashed("the processes"))
    }

    /// The lookup a re-anchor runs: find the passage in a page whose text breaks lines and
    /// hyphenates words in places the quote knows nothing about.
    func testLocateFindsAPassageAcrossLineBreaksAndHyphens() throws {
        let page = """
        4 The Abstraction: The Process
        In this chapter we discuss the abstrac-
        tion the OS provides to users: the process.
        """
        let range = try XCTUnwrap(PDFSelectionText.locate(
            "we discuss the abstraction the OS provides", in: page))
        let found = (page as NSString).substring(with: range)
        XCTAssertEqual(PDFSelectionText.squashed(found),
                       PDFSelectionText.squashed("we discuss the abstraction the OS provides"))
    }

    /// Page text is not ASCII. A combining accent or an emoji before the passage used to
    /// shift the answer by a character or lose it outright, because the squashed side was
    /// counted in Swift Characters and the source side in UTF-16 units.
    func testLocateIsExactAroundCombiningMarksAndEmoji() throws {
        let accented = "e\u{301} target here"
        let range = try XCTUnwrap(PDFSelectionText.locate("target", in: accented))
        XCTAssertEqual((accented as NSString).substring(with: range), "target")

        let withEmoji = "hello 😀 target world"
        let afterEmoji = try XCTUnwrap(PDFSelectionText.locate("target", in: withEmoji))
        XCTAssertEqual((withEmoji as NSString).substring(with: afterEmoji), "target")

        let emojiItself = "hello 😀 world"
        let emoji = try XCTUnwrap(PDFSelectionText.locate("😀", in: emojiItself))
        XCTAssertEqual((emojiItself as NSString).substring(with: emoji), "😀")
    }

    func testLocateMissesWhenThePassageIsNotThere() {
        XCTAssertNil(PDFSelectionText.locate("a passage that never appears", in: "some other page"))
    }

    func testEmptySelectionStaysEmpty() {
        XCTAssertEqual(PDFSelectionText.unwrapped("   \n\n "), "")
    }
}
