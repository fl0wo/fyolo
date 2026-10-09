import XCTest
@testable import fyolo

/// The untracked-flood behavior: a repo with thousands of unignored build products must not
/// cost thousands of file reads, and the in-app .gitignore repair must actually silence them.
final class GitServiceScaleTests: XCTestCase {
    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("fyolo-git-scale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    private func git(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = repo
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " ")) failed")
    }

    private func write(_ relative: String, _ contents: Data) throws {
        let url = repo.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url)
    }

    func testUntrackedTextAndBinaryCounts() async throws {
        try write("a.swift", Data("one\ntwo\nthree".utf8))
        try write("blob.o", Data([0x00, 0x01, 0x02, 0x4D, 0x00]))
        let scans = LockedCounter()
        let changes = await GitService.changes(in: repo.path) { scans.increment() }
        let text = changes.first { $0.path == "a.swift" }
        let binary = changes.first { $0.path == "blob.o" }
        // No trailing newline still counts the last line — matches the old String-split count.
        XCTAssertEqual(text?.additions, 3)
        XCTAssertEqual(binary?.isBinary, true)
        XCTAssertEqual(binary?.additions, 0)
        XCTAssertEqual(scans.value, 2, "each untracked file below the flood limit should be scanned")
    }

    func testUntrackedFloodSkipsLineCounts() async throws {
        for i in 0..<(GitService.untrackedCountLimit + 20) {
            try write(".build/f\(i).txt", Data("x\ny\n".utf8))
        }
        let scans = LockedCounter()
        let changes = await GitService.changes(in: repo.path) { scans.increment() }
        XCTAssertGreaterThan(changes.count, GitService.untrackedCountLimit)
        // Every row keeps its untracked status and the scanner is never invoked.
        XCTAssertTrue(changes.allSatisfy { $0.isUntracked && $0.additions == 0 })
        XCTAssertEqual(scans.value, 0)
    }

    func testLineCountBoundaries() async throws {
        // Trailing newline must NOT add a phantom line (the old String-split did: "x\ny\n"
        // split non-omitting gave ["x","y",""] = 3); git counts 2 and so do we now.
        try write("terminated.txt", Data("x\ny\n".utf8))
        try write("empty.txt", Data())
        try write("blank.txt", Data("\n".utf8))
        let changes = await GitService.changes(in: repo.path)
        XCTAssertEqual(changes.first { $0.path == "terminated.txt" }?.additions, 2)
        XCTAssertEqual(changes.first { $0.path == "empty.txt" }?.additions, 0)
        XCTAssertEqual(changes.first { $0.path == "blank.txt" }?.additions, 1)
    }

    func testGitignorePatternEscapesLiteralNames() async throws {
        // Names full of glob metacharacters and a trailing space must ignore exactly
        // themselves — proven by git's own matcher, not our reading of the spec.
        let names = [
            "we ird *[a].txt",
            "quest?.txt",
            "back\\slash.txt",
            "#lead.txt",
            "!bang.txt",
            "trail.txt ",
        ]
        let decoys = ["we ird Xa.txt", "questX.txt"]
        for name in names {
            try write(name, Data("x".utf8))
            let pattern = try XCTUnwrap(GitService.gitignorePattern(for: name))
            let succeeded = await GitService.appendToGitignore([pattern], in: repo.path)
            XCTAssertTrue(succeeded)
        }
        for name in decoys { try write(name, Data("keep".utf8)) }
        XCTAssertNil(GitService.gitignorePattern(for: "new\nline.txt"))
        XCTAssertNil(GitService.gitignorePattern(for: "return\r.txt"))
        let changes = await GitService.changes(in: repo.path)
        XCTAssertEqual(
            Set(changes.map(\.path)),
            Set([".gitignore"] + decoys),
            "literal patterns must ignore their own file and no similarly named file"
        )
    }

    func testAppendToGitignoreAppendsWithoutRewriting() async throws {
        // Existing contents (even non-UTF8 bytes) must survive an append untouched.
        let original = Data([0x23, 0x20, 0xFF, 0xFE, 0x0A]) // "# " + invalid UTF-8 + newline
        try original.write(to: repo.appendingPathComponent(".gitignore"))
        let succeeded = await GitService.appendToGitignore(["/x.txt"], in: repo.path)
        XCTAssertTrue(succeeded)
        let after = try Data(contentsOf: repo.appendingPathComponent(".gitignore"))
        XCTAssertEqual(after.prefix(original.count), original)
        XCTAssertTrue(String(decoding: after, as: UTF8.self).hasSuffix("/x.txt\n"))
    }

    func testConcurrentGitignoreAppendsDoNotOverwriteEachOther() async throws {
        async let first = GitService.appendToGitignore(["/one.txt"], in: repo.path)
        async let second = GitService.appendToGitignore(["/two.txt"], in: repo.path)
        let results = await (first, second)
        XCTAssertTrue(results.0)
        XCTAssertTrue(results.1)
        let text = try String(
            contentsOf: repo.appendingPathComponent(".gitignore"), encoding: .utf8
        )
        XCTAssertEqual(Set(text.split(separator: "\n").map(String.init)), ["/one.txt", "/two.txt"])
    }

    func testAppendToGitignoreReportsWriteFailure() async throws {
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".gitignore"),
            withIntermediateDirectories: false
        )
        let succeeded = await GitService.appendToGitignore(["/x.txt"], in: repo.path)
        XCTAssertFalse(succeeded)
    }

    func testAppendToGitignoreCreatesDeduplicatesAndSilences() async throws {
        try write(".build/junk.o", Data("junk".utf8))
        let first = await GitService.appendToGitignore(["/.build/"], in: repo.path)
        let second = await GitService.appendToGitignore(["/.build/"], in: repo.path)
        XCTAssertTrue(first)
        XCTAssertTrue(second) // idempotent
        let gitignore = try String(
            contentsOf: repo.appendingPathComponent(".gitignore"), encoding: .utf8
        )
        XCTAssertEqual(gitignore.components(separatedBy: "/.build/").count, 2, "pattern duplicated")
        // The flood is actually silenced (the .gitignore itself shows up as untracked instead).
        let changes = await GitService.changes(in: repo.path)
        XCTAssertEqual(changes.map(\.path), [".gitignore"])
    }

    /// A clean repo and a folder git knows nothing about both yield an empty change
    /// list, so the pane can only tell them apart through this probe — without it a
    /// loose terminal sitting in `$HOME` claimed its working tree was clean.
    func testWorkTreeProbeSeparatesACleanRepoFromAPlainFolder() async throws {
        let plain = FileManager.default.temporaryDirectory
            .appendingPathComponent("fyolo-git-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }

        let repoChanges = await GitService.changes(in: repo.path)
        let plainChanges = await GitService.changes(in: plain.path)
        XCTAssertTrue(repoChanges.isEmpty)
        XCTAssertTrue(plainChanges.isEmpty, "an empty list is what makes the two ambiguous")

        let isRepo = await GitService.isWorkTree(at: repo.path)
        let isPlain = await GitService.isWorkTree(at: plain.path)
        XCTAssertTrue(isRepo)
        XCTAssertFalse(isPlain)
    }
}
