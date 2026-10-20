import XCTest
@testable import fyolo

/// ⌘ held anywhere on a path written in a file underlines the whole path, not one word of it.
final class PathReferenceTests: XCTestCase {
    /// The reference around the `offset`-th character of `marker`'s first occurrence in `text`.
    private func reference(_ text: String, at marker: String, offset: Int = 0) -> PathReference? {
        let string = text as NSString
        let found = string.range(of: marker)
        XCTAssertNotEqual(found.location, NSNotFound, "\(marker) is not in the text")
        return PathReference.at(found.location + offset, in: string)
    }

    private func covered(_ text: String, _ found: PathReference?) -> String? {
        found.map { (text as NSString).substring(with: $0.range) }
    }

    func testEveryPartOfAMakefileScriptPathIsTheWholePath() {
        let text = "test:\n\t@bash hack/test.sh --verbose\n"
        for (marker, offset) in [("hack", 0), ("/test", 0), ("test.sh", 2), (".sh ", 1)] {
            let found = reference(text, at: marker, offset: offset)
            XCTAssertEqual(found?.path, "hack/test.sh", marker)
            XCTAssertEqual(covered(text, found), "hack/test.sh", marker)
            XCTAssertNil(found?.line, marker)
        }
    }

    func testAPlainWordIsNotAPath() {
        let text = "\t@bash hack/test.sh\n"
        XCTAssertNil(reference(text, at: "bash"))
        XCTAssertNil(reference("let total = 3.14", at: "3.14"))
        XCTAssertNil(reference("make build", at: "build"))
    }

    func testMakesSilencingAtIsNotPartOfThePath() {
        let text = "\t@./scripts/run.sh\n"
        let found = reference(text, at: "run")
        XCTAssertEqual(found?.path, "./scripts/run.sh")
        XCTAssertEqual(covered(text, found), "./scripts/run.sh")
    }

    func testALineSuffixIsPartOfTheLinkWhereverThePointerIs() {
        let text = "error at src/app.rs:42:7: expected `;`"
        for marker in ["app", "42", "7:"] {
            let found = reference(text, at: marker)
            XCTAssertEqual(found?.path, "src/app.rs", marker)
            XCTAssertEqual(found?.line, 42, marker)
            XCTAssertEqual(covered(text, found), "src/app.rs:42:7", marker)
        }
    }

    func testSentencePunctuationIsNotPartOfThePath() {
        let text = "See docs/README.md."
        let found = reference(text, at: "docs")
        XCTAssertEqual(found?.path, "docs/README.md")
        XCTAssertEqual(covered(text, found), "docs/README.md")
    }

    func testQuotesAndFlagsEndAPath() {
        let quoted = "source \"./env/dev.sh\""
        XCTAssertEqual(covered(quoted, reference(quoted, at: "dev")), "./env/dev.sh")
        let flag = "deploy --config=deploy/app.yml"
        XCTAssertEqual(reference(flag, at: "app.yml")?.path, "deploy/app.yml")
    }

    func testAPathAfterAVariableIsReadFromTheCheckout() {
        let text = "\t$(CURDIR)/hack/build.sh\n"
        let found = reference(text, at: "build")
        XCTAssertEqual(found?.path, "hack/build.sh")
        XCTAssertEqual(covered(text, found), "/hack/build.sh")
    }

    func testTheHoveredEntryOfAColonListIsThePath() {
        let text = "PATH=tools/bin:node_modules/.bin"
        XCTAssertEqual(reference(text, at: "node_modules")?.path, "node_modules/.bin")
        XCTAssertEqual(reference(text, at: "tools")?.path, "tools/bin")
    }

    func testAURLIsNotAFilePath() {
        XCTAssertNil(reference("curl https://example.com/install.sh", at: "install"))
    }

    func testCandidatesTryBesideTheFileThenTheRoot() {
        XCTAssertEqual(
            PathReference.candidates(for: "hack/test.sh", from: "Makefile", root: "/r"),
            ["hack/test.sh"])
        XCTAssertEqual(
            PathReference.candidates(for: "hack/test.sh", from: "svc/Makefile", root: "/r"),
            ["svc/hack/test.sh", "hack/test.sh"])
        XCTAssertEqual(
            PathReference.candidates(for: "../lib/x.sh", from: "svc/Makefile", root: "/r"),
            ["lib/x.sh"])
    }

    func testCandidatesNeverLeaveTheRoot() {
        XCTAssertEqual(PathReference.candidates(for: "../../x.sh", from: "a/f", root: "/r"), [])
        XCTAssertEqual(PathReference.candidates(for: "/etc/hosts", from: "f", root: "/r"), [])
        XCTAssertEqual(
            PathReference.candidates(for: "/r/hack/test.sh", from: "f", root: "/r"),
            ["hack/test.sh"])
    }
}
