import AppKit
import XCTest
@testable import fyolo

/// The file tree's marks are rules about how the world names things — every ecosystem's
/// test and generated-file conventions, and every toolchain's error format. Each case here
/// is one such convention, so a rule that is loosened or tightened shows which projects it
/// moves.
final class FileDecorationTests: XCTestCase {
    private func kind(_ path: String, directory: Bool = false) -> FileDecoration.Kind? {
        FileClassifier.kind(of: path, isDirectory: directory)
    }

    // MARK: Tests

    func testTestFilesAcrossEcosystems() {
        let tests = [
            "src/button.test.tsx", "src/user.spec.ts", "app/login.e2e.ts", "web/form.cy.ts",
            "pkg/parser_test.go", "lib/test_parser.py", "lib/parser_test.py", "spec/user_spec.rb",
            "test/user_test.exs", "lib/widget_test.dart", "src/ParserTests.swift",
            "src/main/UserServiceTest.java", "src/CheckoutIT.java", "src/RouterSpec.hs",
            "src/setupTests.js", "R/test-utils.R", "src/codec_unittest.cc", "src/db_SUITE.erl",
            "t/basic.t", "src/__snapshots__/x.snap", "conftest.py", "jest.config.ts",
            "vitest.config.mts", "playwright.config.ts", "src/tests.rs", "src/test.py",
        ]
        for path in tests { XCTAssertEqual(kind(path), .test, path) }
    }

    func testTestFoldersMarkThemselvesAndEverythingInside() {
        XCTAssertEqual(kind("tests", directory: true), .test)
        XCTAssertEqual(kind("Tests/fyoloTests", directory: true), .test)
        XCTAssertEqual(kind("src/__tests__/helpers.ts"), .test)
        XCTAssertEqual(kind("src/test/java/com/x/Helper.java"), .test)
        XCTAssertEqual(kind("app/src/androidTest/Thing.kt"), .test)
        XCTAssertEqual(kind("pkg/testdata/input.json"), .test)
        XCTAssertEqual(kind("AppUITests", directory: true), .test)
    }

    func testOrdinarySourceIsNotATest() {
        let source = [
            "src/latest.ts", "src/Latest.swift", "src/Contest.java", "src/ABTest.swift",
            "src/manifest.json", "src/attest.go", "src/testing.go", "src/protest.py",
            "src/Commit.java", "README.md", "src/testimonials.tsx", "Sources/App/Spectrum.swift",
        ]
        for path in source { XCTAssertNil(kind(path), path) }
    }

    // MARK: Generated

    func testLockfilesAndGeneratorOutputAreGenerated() {
        let generated = [
            "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "Cargo.lock",
            "go.sum", "Gemfile.lock", "composer.lock", "poetry.lock", "uv.lock",
            "Package.resolved", "Podfile.lock", "flake.lock", ".terraform.lock.hcl",
            "android/buildscript-gradle.lockfile", "dist/app.min.js", "dist/app.js.map",
            "api/user.pb.go", "api/user_grpc.pb.go", "api/user_pb2.py", "lib/model.g.dart",
            "lib/model.freezed.dart", "Forms/Main.Designer.cs", "src/routeTree.gen.ts",
            "schema.generated.graphql", "pkg/zz_generated.deepcopy.go", "src/__generated__/q.ts",
            "next-env.d.ts",
        ]
        for path in generated { XCTAssertEqual(kind(path), .generated, path) }
    }

    func testGeneratedWinsOverTest() {
        XCTAssertEqual(kind("tests/fixtures_pb2.py"), .generated)
        XCTAssertEqual(kind("tests/package-lock.json"), .generated)
    }

    func testHandWrittenManifestsAreNotGenerated() {
        for path in ["package.json", "Cargo.toml", "go.mod", "Package.swift", "src/index.d.ts", "src/lock.ts"] {
            XCTAssertNil(kind(path), path)
        }
    }

    // MARK: Generated folders

    private func generatedFolders(_ files: [String]) -> Set<String> {
        FileTreeDecorations.generatedFolders(files: files, isGenerated: FileClassifier.isGenerated)
    }

    func testAFolderOfGeneratedFilesIsGeneratedAndSoAreItsAllGeneratedParents() {
        let folders = generatedFolders([
            "api/gen/v1/user.pb.go", "api/gen/v1/order.pb.go", "api/gen/v2/user_pb2.py",
            "api/locks/yarn.lock", "src/index.ts", "src/vendor/app.min.js",
        ])
        XCTAssertEqual(folders, ["api", "api/gen", "api/gen/v1", "api/gen/v2", "api/locks", "src/vendor"])
    }

    func testOneHandWrittenFileAnywhereBelowKeepsAFolderPlain() {
        let folders = generatedFolders(["api/gen/user.pb.go", "api/gen/README.md", "api/client/x.pb.go"])
        XCTAssertEqual(folders, ["api/client"])
        XCTAssertFalse(folders.contains("api"))
    }

    /// The pass a 250k-file checkout pays when its shape changes, off the main thread.
    func testTheWholeTreePassStaysCheapAtTheListingLimit() {
        let files = (0..<250_000).map { index in
            "packages/p\(index % 500)/src/module\(index % 40)/file\(index).\(index % 7 == 0 ? "pb.go" : "ts")"
        }
        let start = Date()
        _ = generatedFolders(files)
        // Measured in a debug build, which runs several times slower than the app.
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    // MARK: Git

    private func change(_ path: String, _ status: GitFileStatus) -> GitChange {
        GitChange(path: path, status: status, isUntracked: status == .untracked)
    }

    func testABranchsNewFileStaysNewThroughLaterEdits() {
        let merged = FileTreeDecorations.merge(
            working: [change("a.swift", .modified), change("c.swift", .untracked)],
            branch: [change("a.swift", .added), change("b.swift", .modified)])
        XCTAssertEqual(merged["a.swift"], .added)
        XCTAssertEqual(merged["b.swift"], .modified)
        XCTAssertEqual(merged["c.swift"], .added)
    }

    func testDeletionsLeaveNoMarkAndARecreatedFileIsModified() {
        let merged = FileTreeDecorations.merge(
            working: [change("gone.swift", .deleted), change("back.swift", .untracked)],
            branch: [change("gone.swift", .modified), change("back.swift", .deleted)])
        XCTAssertNil(merged["gone.swift"])
        XCTAssertEqual(merged["back.swift"], .modified)
    }

    /// The whitespace check, against a real repository: re-indenting C is cosmetic,
    /// re-indenting Python is not, and a real edit is never cosmetic.
    func testCosmeticChangesRespectIndentationSignificantLanguages() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fyolo-cosmetic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ name: String, _ text: String) throws {
            try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        func git(_ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path, "-c", "user.name=t", "-c", "user.email=t@t"] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }
        try git("init", "-q")
        try write("main.c", "int main() {\n  return 0;\n}\n")
        try write("app.py", "if x:\n    y = 1\n")
        try write("real.c", "int a = 1;\n")
        try git("add", "-A")
        try git("commit", "-qm", "base")
        try write("main.c", "int main()   {\n\n        return 0;\n}\n")
        try write("app.py", "if x:\n  y = 1\n")
        try write("real.c", "int a = 2;\n")

        let cosmetic = await GitService.cosmeticChanges(["main.c", "app.py", "real.c"], against: nil, in: root.path)
        XCTAssertEqual(cosmetic, ["main.c"])
    }

    // MARK: Palette

    func testNameInksStayLegibleOnEveryBackground() {
        let backgrounds: [(NSColor, Bool)] = [
            (.white, false), (NSColor(srgbRed: 0.13, green: 0.13, blue: 0.13, alpha: 1), true),
            (NSColor(srgbRed: 0.99, green: 0.96, blue: 0.89, alpha: 1), false),
            (NSColor(srgbRed: 0.0, green: 0.17, blue: 0.21, alpha: 1), true),
        ]
        for (background, dark) in backgrounds {
            let palette = FileTreePalette(background: background, isDark: dark)
            XCTAssertGreaterThanOrEqual(Palette.contrastRatio(palette.generatedInk, background), 4.5)
            for kind in [FileDecoration.Kind?.none, .test, .generated] {
                let decoration = FileDecoration(kind: kind)
                let surface = palette.fill(for: decoration) ?? background
                XCTAssertGreaterThanOrEqual(
                    Palette.contrastRatio(palette.ink(for: .added, on: decoration), surface), 4.5)
                XCTAssertGreaterThanOrEqual(
                    Palette.contrastRatio(palette.ink(for: .modified, on: decoration), surface), 3)
                XCTAssertGreaterThanOrEqual(
                    Palette.contrastRatio(palette.ink(for: .cosmetic, on: decoration), surface), 4.5)
            }
        }
    }

    /// "Less bright": a modified file's green sits between the background and an added
    /// file's green.
    func testModifiedGreenIsQuieterThanAdded() {
        for (background, dark) in [(NSColor.white, false), (NSColor.black, true)] {
            let palette = FileTreePalette(background: background, isDark: dark)
            let added = palette.ink(for: .added, on: FileDecoration())
            let modified = palette.ink(for: .modified, on: FileDecoration())
            XCTAssertLessThan(Palette.contrastRatio(modified, background), Palette.contrastRatio(added, background))
        }
    }

    // MARK: Headers

    func testGeneratorHeadersAreRecognized() {
        let headers = [
            "// Code generated by protoc-gen-go. DO NOT EDIT.\npackage x\n",
            "# Generated by the protocol buffer compiler.  DO NOT EDIT!\n",
            "/**\n * @generated SignedSource<<abc>>\n */\n",
            "//------\n// <auto-generated>\n//     This code was generated by a tool.\n",
            "/* Autogenerated by Thrift Compiler (0.19.0) */\n",
        ]
        for header in headers { XCTAssertTrue(FileClassifier.hasGeneratedHeader(Data(header.utf8)), header) }
        XCTAssertFalse(FileClassifier.hasGeneratedHeader(Data("import Foundation\n\nlet x = 1\n".utf8)))
        let late = String(repeating: "let x = 1\n", count: 200) + "// DO NOT EDIT\n"
        XCTAssertFalse(FileClassifier.hasGeneratedHeader(Data(late.utf8)))
    }
}

/// One toolchain per case: what it prints when a file fails to build, and what it prints
/// that must not be read as one.
final class TerminalDiagnosticScannerTests: XCTestCase {
    private func errors(_ output: String) -> [String] {
        var scanner = TerminalDiagnosticScanner()
        return scanner.feed(Data(output.utf8)).compactMap {
            if case .error(let path) = $0 { return path }
            return nil
        }
    }

    func testOneLineFormats() {
        let cases: [(String, String)] = [
            ("/Users/me/My App/Sources/App.swift:12:5: error: cannot find 'x' in scope\n", "/Users/me/My App/Sources/App.swift"),
            ("src/main.c:3:1: fatal error: 'foo.h' file not found\n", "src/main.c"),
            ("src/a.ts(12,5): error TS2304: Cannot find name 'x'.\n", "src/a.ts"),
            ("src/a.ts:12:5 - error TS2304: Cannot find name 'x'.\n", "src/a.ts"),
            ("/x/app.py:4:1 - error: \"y\" is not defined (reportUndefinedVariable)\n", "/x/app.py"),
            ("app/models.py:12: error: Incompatible return value type\n", "app/models.py"),
            ("Foo.java:7: error: cannot find symbol\n", "Foo.java"),
            ("src/Lib.hs:3:8: error: [GHC-88464]\n", "src/Lib.hs"),
            ("lib/main.dart:4:3: Error: Undefined name 'x'.\n", "lib/main.dart"),
            ("src/main.zig:2:5: error: use of undeclared identifier\n", "src/main.zig"),
            ("lib/a.rb:3: syntax error, unexpected end-of-input\n", "lib/a.rb"),
            ("/src/Program.cs(10,13): error CS1002: ; expected [/src/App.csproj]\n", "/src/Program.cs"),
            ("e: file:///p/src/Main.kt:3:5 Unresolved reference: foo\n", "/p/src/Main.kt"),
            ("[error] /p/src/Main.scala:3:5: not found: value x\n", "/p/src/Main.scala"),
            ("[ERROR] /p/src/Main.java:[12,5] cannot find symbol\n", "/p/src/Main.java"),
            ("PHP Parse error:  syntax error, unexpected '}' in /var/www/index.php on line 9\n", "/var/www/index.php"),
            ("CMake Error at CMakeLists.txt:12 (add_executable):\n", "CMakeLists.txt"),
            ("ERROR in ./src/index.tsx 4:7-12\n", "./src/index.tsx"),
            ("./main.go:12:5: undefined: foo\n", "./main.go"),
        ]
        for (output, path) in cases { XCTAssertEqual(errors(output), [path], output) }
    }

    func testHeaderThenLocationFormats() {
        XCTAssertEqual(errors("""
        error[E0425]: cannot find value `y` in this scope
         --> src/main.rs:2:13
          |
        2 |     let x = y;

        """), ["src/main.rs"])
        XCTAssertEqual(errors("""
            error: undefined variable "x"
            │
         12 │     x + 1
            │     ^
            │
            └─ lib/app.ex:12:5: App.run/0

        """), ["lib/app.ex"])
        XCTAssertEqual(errors("""
        ✘ [ERROR] Could not resolve "missing"

            src/main.ts:1:7:
              1 │ import "missing"

        """), ["src/main.ts"])
        XCTAssertEqual(errors("""
        ╷
        │ Error: Unsupported argument
        │
        │   on main.tf line 12, in resource "aws_s3_bucket" "b":

        """), ["main.tf"])
    }

    func testTracebacksCountOnlyWhenTheFileItselfIsBroken() {
        XCTAssertEqual(errors("""
          File "/p/app/views.py", line 3
            def broken(:
                       ^
        SyntaxError: invalid syntax

        """), ["/p/app/views.py"])
        XCTAssertEqual(errors("""
        Traceback (most recent call last):
          File "/p/run.py", line 2, in <module>
            d["k"]
        KeyError: 'k'

        """), [])
    }

    func testESLintStylish() {
        XCTAssertEqual(errors("""
        /p/src/app.js
          3:7   error    'x' is assigned a value but never used  no-unused-vars
          5:1   warning  Unexpected console statement            no-console

        ✖ 2 problems (1 error, 1 warning)

        """), ["/p/src/app.js"])
    }

    func testWarningsAreNotErrors() {
        XCTAssertEqual(errors("""
        warning: unused variable: `x`
         --> src/main.rs:2:9
        src/a.c:1:1: warning: unused function
        src/a.ts:12:5 - warning: deprecated
        error: could not compile `app` due to previous error
        src/b.swift:3:1: warning: will never be executed

        """), [])
    }

    func testEscapesAndCarriageReturnsAreStripped() {
        // A hyperlink escape around the path is not part of it.
        XCTAssertEqual(errors("\u{1B}]8;;file:///p/src/a.c\u{07}src/a.c\u{1B}]8;;\u{1B}\\:1:2: error: boom\n"), ["src/a.c"])
        XCTAssertEqual(errors("\u{1B}[1msrc/a.c:1:2: \u{1B}[31merror:\u{1B}[0m boom\n"), ["src/a.c"])
        XCTAssertEqual(errors("Compiling 1/3\rCompiling 2/3\rsrc/a.c:1:2: error: boom\r\n"), ["src/a.c"])
        // A TUI that moves the cursor between rows instead of printing newlines.
        XCTAssertEqual(errors("  ⎿  src/a.c:1:2: error: boom\u{1B}[2;1Hnext row"), ["src/a.c"])
    }

    func testChunksSplitMidLine() {
        var scanner = TerminalDiagnosticScanner()
        XCTAssertEqual(scanner.feed(Data("src/a.c:1:2: err".utf8)), [])
        XCTAssertEqual(scanner.feed(Data("or: boom\n".utf8)), [.error(path: "src/a.c")])
    }

    func testCleanBuilds() {
        for line in [
            "Build complete! (12.34s)", "** BUILD SUCCEEDED **", "BUILD SUCCESSFUL in 3s",
            "    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.52s",
            "[12:00:00 PM] Found 0 errors. Watching for file changes.",
            "webpack 5.90.0 compiled successfully in 812 ms", "Success: no issues found in 3 source files",
            "0 errors, 0 warnings, 0 informations ",
        ] {
            var scanner = TerminalDiagnosticScanner()
            XCTAssertEqual(scanner.feed(Data((line + "\n").utf8)), [.clean], line)
        }
        var scanner = TerminalDiagnosticScanner()
        XCTAssertEqual(scanner.feed(Data("Found 10 errors.\n10 errors, 0 warnings\n".utf8)), [])
    }

    func testResolution() {
        XCTAssertEqual(TerminalDiagnostics.resolve("src/../lib/./a.ts", from: "/p", isLocal: false), "/p/lib/a.ts")
        XCTAssertEqual(TerminalDiagnostics.resolve("file:///p/a.kt", from: nil, isLocal: false), "/p/a.kt")
        XCTAssertNil(TerminalDiagnostics.resolve("a.ts", from: nil, isLocal: true))
        XCTAssertNil(TerminalDiagnostics.resolve("~/a.ts", from: "/p", isLocal: false))
    }
}
