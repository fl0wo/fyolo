import XCTest
@testable import fyolo

/// The find bar's replace half. Everything here is a case someone would notice getting wrong: a
/// `$1` that came out literal, a Replace All that needed a hundred ⌘Z presses to take back, a
/// replacement that matched itself and got replaced again on the next press.
final class FindReplaceTests: XCTestCase {
    private let literal = FindOptions()
    private let regex = FindOptions(caseSensitive: false, wholeWord: false, regex: true)

    /// The whole document after `edit` lands — the string the text view would be holding.
    private func applying(_ edit: FindReplace.Replacement, to text: NSString) -> String {
        let result = NSMutableString(string: text)
        result.replaceCharacters(in: edit.range, with: edit.text)
        return result as String
    }

    /// Every match run through `plan` + `coalesced` and applied, which is exactly what Replace All
    /// does to the buffer.
    private func replacingAll(
        _ query: String, with template: String, options: FindOptions, in source: String
    ) -> String {
        let text = source as NSString
        let plan = FindReplace.plan(query: query, options: options, template: template, in: text)
        guard let edit = FindReplace.coalesced(plan, in: text) else { return source }
        return applying(edit, to: text)
    }

    // MARK: Planning

    func testLiteralPlanPairsEveryMatchWithTheTemplate() {
        let text = "one two one two one" as NSString
        let plan = FindReplace.plan(query: "one", options: literal, template: "1", in: text)
        XCTAssertEqual(plan.map(\.range), [NSRange(location: 0, length: 3),
                                          NSRange(location: 8, length: 3),
                                          NSRange(location: 16, length: 3)])
        XCTAssertEqual(Set(plan.map(\.text)), ["1"])
    }

    /// The ranges the bar counts and the ranges Replace acts on must be the same list, or the
    /// "n of m" counter is lying about what the next press will touch.
    func testPlanRangesMatchTheEnginesMatchList() {
        let text = "Foo foo FOO foobar" as NSString
        for options in [literal,
                        FindOptions(caseSensitive: true, wholeWord: false, regex: false),
                        FindOptions(caseSensitive: false, wholeWord: true, regex: false)] {
            XCTAssertEqual(
                FindReplace.plan(query: "foo", options: options, template: "x", in: text).map(\.range),
                TextFindEngine.matches(of: "foo", options: options, in: text))
        }
    }

    func testEmptyQueryOrEmptyDocumentPlansNothing() {
        XCTAssertTrue(FindReplace.plan(query: "", options: literal, template: "x", in: "abc").isEmpty)
        XCTAssertTrue(FindReplace.plan(query: "abc", options: literal, template: "x", in: "").isEmpty)
    }

    /// A pattern that doesn't parse yet — the user is still typing it — replaces nothing rather
    /// than falling back to a literal search for the pattern text.
    func testUnparseablePatternPlansNothing() {
        let text = "a(b(c" as NSString
        XCTAssertTrue(FindReplace.plan(query: "(unclosed", options: regex, template: "x", in: text).isEmpty)
    }

    // MARK: Capture groups

    func testRegexTemplateExpandsCaptureGroups() {
        let text = "let a = 1\nlet b = 2\n" as NSString
        XCTAssertEqual(
            replacingAll(#"let (\w+) = (\d+)"#, with: "var $1: Int = $2", options: regex, in: text as String),
            "var a: Int = 1\nvar b: Int = 2\n")
    }

    func testRegexTemplateExpandsTheWholeMatchAndEscapesADollar() {
        let text = "price 10" as NSString
        XCTAssertEqual(replacingAll(#"\d+"#, with: "[$0]", options: regex, in: text as String), "price [10]")
        // A backslash-escaped dollar is a literal one — the only way to type a dollar sign into a
        // regex-mode replacement.
        XCTAssertEqual(replacingAll(#"\d+"#, with: #"\$$0"#, options: regex, in: text as String), "price $10")
    }

    /// A group the pattern doesn't have expands to nothing rather than raising.
    func testMissingCaptureGroupExpandsToNothing() {
        XCTAssertEqual(replacingAll("(a)", with: "$2", options: regex, in: "abc"), "bc")
    }

    /// In literal mode there are no groups to name, so `$1` is just those two characters. Eating a
    /// dollar sign out of replaced text would be a worse answer than not offering the feature.
    func testLiteralModeTreatsDollarAsPlainText() {
        XCTAssertEqual(replacingAll("cost", with: "$1", options: literal, in: "cost and cost"),
                       "$1 and $1")
        XCTAssertEqual(replacingAll("USD", with: #"\$"#, options: literal, in: "10 USD"), #"10 \$"#)
    }

    func testWholeWordFilterAppliesToRegexReplacements() throws {
        let text = "cat category cat" as NSString
        var options = regex
        options.wholeWord = true
        let plan = FindReplace.plan(query: "cat", options: options, template: "dog", in: text)
        XCTAssertEqual(plan.map(\.range), [NSRange(location: 0, length: 3), NSRange(location: 13, length: 3)])
        XCTAssertEqual(applying(try XCTUnwrap(FindReplace.coalesced(plan, in: text)), to: text),
                       "dog category dog")
    }

    // MARK: One edit for the whole document

    /// Replace All is one `replaceCharacters` over one range — one edit is one undo step, which is
    /// the whole reason the replacements are coalesced instead of applied one at a time.
    func testReplaceAllCoalescesIntoASingleEdit() throws {
        let text = "a x a x a" as NSString
        let plan = FindReplace.plan(query: "a", options: literal, template: "bb", in: text)
        XCTAssertEqual(plan.count, 3)
        let edit = try XCTUnwrap(FindReplace.coalesced(plan, in: text))
        // One range, reaching from the first match's start to the last match's end — the text
        // between the matches is carried along inside the replacement, untouched.
        XCTAssertEqual(edit.range, NSRange(location: 0, length: 9))
        XCTAssertEqual(edit.text, "bb x bb x bb")
        XCTAssertEqual(applying(edit, to: text), "bb x bb x bb")
    }

    /// The span stops at the last match: text before the first and after the last is never part of
    /// the edit, so an undo restores exactly what was replaced.
    func testCoalescedEditSpansOnlyTheMatches() throws {
        let text = "head one tail" as NSString
        let plan = FindReplace.plan(query: "one", options: literal, template: "two", in: text)
        let edit = try XCTUnwrap(FindReplace.coalesced(plan, in: text))
        XCTAssertEqual(edit.range, NSRange(location: 5, length: 3))
        XCTAssertEqual(edit.text, "two")
        XCTAssertEqual(applying(edit, to: text), "head two tail")
    }

    func testNothingToReplaceCoalescesToNoEdit() {
        XCTAssertNil(FindReplace.coalesced([], in: "abc"))
    }

    /// An empty replacement field deletes the matches, the way it does everywhere else.
    func testEmptyTemplateDeletesEveryMatch() {
        XCTAssertEqual(replacingAll(", ", with: "", options: literal, in: "a, b, c"), "abc")
    }

    /// A replacement that contains the query is the case a naive replace-each-match loop never
    /// finishes: the plan is taken over the buffer as it stands, so every match is replaced once.
    func testAReplacementContainingTheQueryIsStillReplacedOnce() {
        XCTAssertEqual(replacingAll("foo", with: "foobar", options: literal, in: "foo foo"),
                       "foobar foobar")
    }

    /// Offsets are UTF-16 units, the unit `NSTextView` selections use — a surrogate pair ahead of a
    /// match must not shift where the edit lands.
    func testOffsetsCountUTF16Units() throws {
        let text = "🙂 one 🙂 one" as NSString
        let plan = FindReplace.plan(query: "one", options: literal, template: "two", in: text)
        XCTAssertEqual(plan.map(\.range), [NSRange(location: 3, length: 3), NSRange(location: 10, length: 3)])
        XCTAssertEqual(applying(try XCTUnwrap(FindReplace.coalesced(plan, in: text)), to: text),
                       "🙂 two 🙂 two")
    }

    // MARK: Where the focus lands afterwards

    /// Replace steps to the first match *past* what it just inserted. Replacing `foo` with
    /// `foobar` otherwise lands back inside the replacement and replaces it again on every press.
    func testFocusStepsPastTheInsertedText() {
        let replaced = "foobar foo foo" as NSString
        let matches = TextFindEngine.matches(of: "foo", options: literal, in: replaced)
        XCTAssertEqual(matches.map(\.location), [0, 7, 11])
        XCTAssertEqual(FindReplace.focusIndex(startingAt: 6, in: matches), 1)
    }

    func testFocusWrapsToTheTopAfterTheLastMatch() {
        let replaced = "one two one" as NSString
        let matches = TextFindEngine.matches(of: "one", options: literal, in: replaced)
        XCTAssertEqual(FindReplace.focusIndex(startingAt: replaced.length, in: matches), 0)
    }

    func testFocusStaysAtTheTopWhenNothingIsLeft() {
        XCTAssertEqual(FindReplace.focusIndex(startingAt: 0, in: []), 0)
    }

    // MARK: Coexisting with the line commands

    /// ⌘/ and Replace land through the same `replaceAsOneEdit`, so a replacement inside a block
    /// that was just commented is still one edit — one range, one undo step — rather than one per
    /// commented line.
    func testReplacingInsideACommentedBlockIsStillOneEdit() throws {
        let source = "let a = old\nlet b = old\n" as NSString
        let marker = try XCTUnwrap(EditorLineCommands.commentMarker(for: "swift"))
        let commented = try XCTUnwrap(EditorLineCommands.toggleComment(
            NSRange(location: 0, length: source.length), in: source, marker: marker))
        let text = applying(
            FindReplace.Replacement(range: commented.range, text: commented.replacement),
            to: source) as NSString
        XCTAssertEqual(text as String, "// let a = old\n// let b = old\n")

        let plan = FindReplace.plan(query: "old", options: literal, template: "new", in: text)
        XCTAssertEqual(plan.count, 2)
        let edit = try XCTUnwrap(FindReplace.coalesced(plan, in: text))
        XCTAssertEqual(edit.range, NSRange(location: 11, length: 18))
        XCTAssertEqual(applying(edit, to: text), "// let a = new\n// let b = new\n")
    }

    /// A line command edits the buffer under a live query, and the find bar recounts from the
    /// notification that edit fires — so the count it lands on has to be the count of the
    /// *commented* text, markers and all.
    func testMatchesStayHonestAfterALineCommand() throws {
        let source = "old\nold\n" as NSString
        XCTAssertEqual(TextFindEngine.matches(of: "old", options: literal, in: source).count, 2)

        let marker = try XCTUnwrap(EditorLineCommands.commentMarker(for: "python"))
        let commented = try XCTUnwrap(EditorLineCommands.toggleComment(
            NSRange(location: 0, length: source.length), in: source, marker: marker))
        let text = applying(
            FindReplace.Replacement(range: commented.range, text: commented.replacement),
            to: source) as NSString
        XCTAssertEqual(text as String, "# old\n# old\n")
        XCTAssertEqual(TextFindEngine.matches(of: "old", options: literal, in: text).map(\.location),
                       [2, 8])
    }

    /// Neither feature can swallow the other's keys: the line-command hook sits on `keyDown`,
    /// which only ever sees what no menu key equivalent claimed, and it claims none of the four
    /// find keys anyway.
    func testTheLineCommandHookIgnoresTheFindKeys() {
        for key in ["f", "g", "e"] {
            XCTAssertNil(EditorLineCommands.command(for: [.command], key: key))
            XCTAssertNil(EditorLineCommands.command(for: [.command, .shift], key: key))
        }
        // And the keys it does claim are ones no find menu item asks for.
        XCTAssertEqual(EditorLineCommands.command(for: [.command], key: "/"), .toggleComment)
    }

    /// Replacing the first of several leaves the focus on what was the second match, which is now
    /// the first — the counter reads "1 of 2" and the next press acts on the right text.
    func testFocusAfterReplacingTheFirstOfSeveral() {
        let source = "cat cat cat" as NSString
        let plan = FindReplace.plan(query: "cat", options: literal, template: "dog", in: source)
        let replaced = applying(plan[0], to: source) as NSString
        XCTAssertEqual(replaced as String, "dog cat cat")
        let remaining = TextFindEngine.matches(of: "cat", options: literal, in: replaced)
        XCTAssertEqual(remaining.count, 2)
        let landed = plan[0].range.location + (plan[0].text as NSString).length
        XCTAssertEqual(FindReplace.focusIndex(startingAt: landed, in: remaining), 0)
    }
}
