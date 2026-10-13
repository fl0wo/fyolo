import XCTest

@testable import fyolo

/// The package.json plugin: which lines get a run button and what each runs.
/// The scan reads a buffer that is often mid-edit, so the cases that matter
/// are the messy ones — nested "scripts" keys, invalid JSON, escapes.
@MainActor
final class PackageScriptsPluginTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("package-scripts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "package-scripts-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private let manifest = """
    {
      "name": "shop",
      "config": { "scripts": { "not-this": "x" } },
      "scripts": {
        "dev": "vite",
        "build:prod": "vite build",
        "say \\"hi\\"": "echo hi"
      },
      "dependencies": { "vite": "^5" }
    }
    """

    func testEveryTopLevelScriptGetsItsOwnLine() {
        let scripts = PackageScriptsPlugin.scriptLines(in: manifest)
        XCTAssertEqual(scripts.map(\.name), ["dev", "build:prod", "say \"hi\""])
        XCTAssertEqual(scripts.map(\.line), [5, 6, 7])
    }

    func testAHalfTypedBufferStillShowsTheScriptsAboveTheCursor() {
        let editing = """
        {
          "scripts": {
            "dev": "vite",
            "test": "vit
        """
        XCTAssertEqual(PackageScriptsPlugin.scriptLines(in: editing).map(\.name), ["dev", "test"])
    }

    func testAScriptsValueThatIsNotAnObjectGivesNoButtons() {
        XCTAssertTrue(PackageScriptsPlugin.scriptLines(in: #"{"scripts": "none", "a": {"b": 1}}"#).isEmpty)
    }

    func testTheDeclaredPackageManagerWins() throws {
        try Data().write(to: directory.appendingPathComponent("yarn.lock"))
        let declared = PackageScriptsPlugin.declaredPackageManager(in: #"{"packageManager": "pnpm@9.1.0"}"#)
        XCTAssertEqual(PackageScriptsPlugin.packageManager(declared: declared, near: directory), "pnpm")
    }

    func testALockfileUpTheTreeNamesTheManager() throws {
        try Data().write(to: directory.appendingPathComponent("pnpm-lock.yaml"))
        let package = directory.appendingPathComponent("packages/web", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        XCTAssertEqual(PackageScriptsPlugin.packageManager(declared: nil, near: package), "pnpm")
    }

    func testOddScriptNamesAreQuotedForTheShell() {
        XCTAssertEqual(RunTask.shellWord("build:prod"), "build:prod")
        XCTAssertEqual(RunTask.shellWord("say \"hi\""), "'say \"hi\"'")
        XCTAssertEqual(RunTask.shellWord("it's"), "'it'\\''s'")
    }

    func testOnlyPackageJsonGetsButtonsAndTheyRunInItsFolder() throws {
        let plugin = PackageScriptsPlugin()
        XCTAssertTrue(plugin.gutterActions(for: directory.appendingPathComponent("tsconfig.json"),
                                           text: manifest).isEmpty)
        let file = directory.appendingPathComponent("package.json")
        let first = try XCTUnwrap(plugin.gutterActions(for: file, text: manifest).first)
        XCTAssertEqual(first.line, 5)
        let task = try XCTUnwrap(first.task)
        XCTAssertEqual(task.name, "dev")
        XCTAssertTrue(task.command.hasSuffix(" run dev"), task.command)
        XCTAssertEqual(task.directory.standardizedFileURL.path, directory.standardizedFileURL.path)
    }

    func testTurningThePluginOffRemovesItsButtons() {
        let settings = AppSettings(
            defaults: defaults,
            settingsStore: SettingsStore(
                defaults: defaults,
                fileURL: directory.appendingPathComponent("settings.json"),
                domainName: suiteName))
        let file = directory.appendingPathComponent("package.json")
        XCTAssertFalse(PluginRegistry.gutterActions(for: file, text: manifest, settings: settings).isEmpty)
        settings.setPlugin(PackageScriptsPlugin().id, enabled: false)
        XCTAssertTrue(PluginRegistry.gutterActions(for: file, text: manifest, settings: settings).isEmpty)
    }
}
