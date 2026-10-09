import XCTest
@testable import fyolo

/// `Highlightr()` fails whenever syntax highlighting cannot be set up — a resource it
/// cannot read, a `JSContext` that will not allocate. Every initializer used to
/// force-unwrap it, so that condition killed the app the moment a file editor was built.
/// The contract now is that the editor still shows the file, just uncolored.
final class CodeAttributedStringTests: XCTestCase {
    func testWithoutAHighlighterTheTextIsStillStored() {
        let storage = CodeAttributedString(highlightr: nil)
        storage.language = "swift"

        storage.append(NSAttributedString(string: "let answer = 42\n"))
        storage.append(NSAttributedString(string: "print(answer)\n"))

        XCTAssertNil(storage.highlightr)
        XCTAssertEqual(storage.string, "let answer = 42\nprint(answer)\n")
    }

    /// Editing is what drives `highlight(_:)`, which is where the nil highlighter is read.
    func testEditingWithoutAHighlighterLeavesTheTextIntact() {
        let storage = CodeAttributedString(highlightr: nil)
        storage.language = "swift"
        storage.append(NSAttributedString(string: "struct Box {}"))

        storage.replaceCharacters(in: NSRange(location: 7, length: 3), with: "Crate")

        XCTAssertEqual(storage.string, "struct Crate {}")
    }

    /// A language of nil already meant "no highlighting"; it must stay that way.
    func testNoLanguageIsStillAccepted() {
        let storage = CodeAttributedString(highlightr: nil)
        storage.append(NSAttributedString(string: "plain text"))

        XCTAssertNil(storage.language)
        XCTAssertEqual(storage.string, "plain text")
    }
}
