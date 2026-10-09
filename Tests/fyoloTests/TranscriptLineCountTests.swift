import XCTest
@testable import fyolo

/// `FyoloStore.lineCount` is the cursor a supervising agent resumes a transcript
/// read from, so it must be the exact newline count for any file shape. It is
/// always a full count (never cached against a mutable file); these pin the
/// counting itself, and that the async wrapper agrees with the synchronous one.
final class TranscriptLineCountTests: XCTestCase {
    private var path = ""

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "fyolo-linecount-\(UUID().uuidString).jsonl"
        try Data().write(to: URL(fileURLWithPath: path))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func write(_ text: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    func testCountsNewlines() throws {
        try write("a\nb\nc\n")
        XCTAssertEqual(FyoloStore.lineCount(of: path), 3)
    }

    func testEmptyFileIsZero() throws {
        XCTAssertEqual(FyoloStore.lineCount(of: path), 0)
    }

    func testNoTrailingNewlineIsNotOverCounted() throws {
        try write("a\nb\nc")            // two newlines, three lines of text
        XCTAssertEqual(FyoloStore.lineCount(of: path), 2)
    }

    func testMissingFileIsZero() throws {
        try FileManager.default.removeItem(atPath: path)
        XCTAssertEqual(FyoloStore.lineCount(of: path), 0)
    }

    func testExactAcrossChunkBoundaries() throws {
        // Well past one 256 KB read, newlines landing on both sides of the edges.
        let lines = 300_000
        try write(String(repeating: "x\n", count: lines) + "tail without newline")
        XCTAssertEqual(FyoloStore.lineCount(of: path), lines)
    }

    func testRewriteIsAlwaysExact() throws {
        try write("a\nb\nc\nd\n")
        XCTAssertEqual(FyoloStore.lineCount(of: path), 4)
        // A full rewrite to fewer lines is reflected immediately — no cached count.
        try write("x\n")
        XCTAssertEqual(FyoloStore.lineCount(of: path), 1)
    }

    func testOffMainMatchesSynchronous() async throws {
        try write("one\ntwo\nthree\nfour\n")
        let async = await FyoloStore.lineCountOffMain(of: path)
        XCTAssertEqual(async, FyoloStore.lineCount(of: path))
        XCTAssertEqual(async, 4)
    }
}
