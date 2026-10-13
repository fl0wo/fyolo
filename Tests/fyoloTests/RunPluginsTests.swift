import XCTest

@testable import fyolo

/// The Makefile and script-file plugins: which lines get a run button, and the
/// exact command each one types.
@MainActor
final class RunPluginsTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("run-plugins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    // MARK: Makefile

    private let makefile = """
    CC := clang
    FLAGS = -O2 -DURL=http://x
    export PATH := bin:$(PATH)
    .PHONY: build test

    build: main.o
    \t$(CC) -o app main.o

    test e2e: build
    \t./run-tests \\
    \t  --all

    %.o: %.c
    \t$(CC) -c $<

    $(OUT): build
    install:: ## copy it
    define HELP
    fake: target
    endef
    lint: \\
      build
    """

    func testOnlyRunnableRulesGetButtons() {
        let targets = MakefilePlugin.targetLines(in: makefile)
        XCTAssertEqual(targets.map(\.name), ["build", "test", "install", "lint"])
        XCTAssertEqual(targets.map(\.line), [6, 9, 17, 21])
    }

    func testADefaultNamedMakefileRunsPlainMake() throws {
        let file = directory.appendingPathComponent("Makefile")
        let first = try XCTUnwrap(MakefilePlugin().gutterActions(for: file, text: makefile).first?.task)
        XCTAssertEqual(first.command, "make build")
        XCTAssertEqual(first.name, "build")
        XCTAssertEqual(first.directory.standardizedFileURL.path, directory.standardizedFileURL.path)
    }

    func testAnIncludedMakefileIsNamedWithDashF() throws {
        let file = directory.appendingPathComponent("release.mk")
        let first = try XCTUnwrap(MakefilePlugin().gutterActions(for: file, text: "ship:\n").first?.task)
        XCTAssertEqual(first.command, "make -f release.mk ship")
    }

    func testOtherFilesGetNoMakeButtons() {
        let file = directory.appendingPathComponent("notes.txt")
        XCTAssertTrue(MakefilePlugin().gutterActions(for: file, text: makefile).isEmpty)
    }

    // MARK: Script files

    func testAShebangNamesTheInterpreter() throws {
        let file = directory.appendingPathComponent("scripts/build app.py")
        let task = try XCTUnwrap(ScriptFilePlugin.task(
            for: file, firstLine: "#!/usr/bin/env python3", root: directory))
        XCTAssertEqual(task.command, "/usr/bin/env python3 'scripts/build app.py'")
        XCTAssertEqual(task.name, "build app.py")
        XCTAssertEqual(task.directory, directory)
    }

    func testAShellFileWithoutAShebangRunsThroughItsShell() throws {
        let file = directory.appendingPathComponent("deploy.zsh")
        let task = try XCTUnwrap(ScriptFilePlugin.task(for: file, firstLine: "echo hi", root: directory))
        XCTAssertEqual(task.command, "zsh deploy.zsh")
    }

    func testAPlainFileIsNotAScript() {
        let file = directory.appendingPathComponent("README.md")
        XCTAssertNil(ScriptFilePlugin.task(for: file, firstLine: "# Title", root: directory))
        XCTAssertNil(ScriptFilePlugin.task(for: file, firstLine: "#!", root: directory))
    }

    func testTheButtonSitsOnLineOneAndTheMenuReadsTheFile() throws {
        let file = directory.appendingPathComponent("go.sh")
        try "#!/bin/bash\necho go\n".write(to: file, atomically: true, encoding: .utf8)
        let plugin = ScriptFilePlugin()
        let marker = try XCTUnwrap(plugin.gutterActions(for: file, text: "#!/bin/bash\necho go\n").first)
        XCTAssertEqual(marker.line, 1)
        XCTAssertEqual(plugin.wholeFileTask(for: file)?.command, marker.task?.command)
        XCTAssertTrue(marker.task?.command.hasPrefix("/bin/bash ") == true)
    }
}
