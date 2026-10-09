import XCTest

@testable import fyolo

/// Exercises the Keychain round trip and the askpass helper against the real
/// `security(1)` and a real `ssh`. The item lives under a test-only service name
/// and is removed in `tearDown`, so nothing touches a password the user saved.
///
/// The end-to-end half — that ssh actually signs in with what the helper prints —
/// needs a server that takes passwords, so it runs only when `FYOLO_TEST_SSH_URL`
/// names one (`tester@localhost:2223`). Without it the mechanism is still covered
/// up to the point ssh would be invoked.
final class SSHPasswordStoreTests: XCTestCase {
    private let alias = "fyolo-tests-\(ProcessInfo.processInfo.processIdentifier)"

    override func tearDown() {
        SSHPasswordStore.remove(for: alias)
        super.tearDown()
    }

    func testSavedPasswordIsFoundAndRemoved() throws {
        XCTAssertFalse(SSHPasswordStore.hasPassword(for: alias))
        try SSHPasswordStore.save("hunter2", for: alias)
        XCTAssertTrue(SSHPasswordStore.hasPassword(for: alias))
        SSHPasswordStore.remove(for: alias)
        XCTAssertFalse(SSHPasswordStore.hasPassword(for: alias))
    }

    /// A password with the characters that break naive shell plumbing. It never
    /// passes through a shell here, and this is what proves it.
    func testAwkwardPasswordSurvivesTheRoundTrip() throws {
        let awkward = #"p@ss "w'rd $(echo no) \ %s"#
        try SSHPasswordStore.save(awkward, for: alias)
        XCTAssertEqual(try helperOutput(), awkward)
    }

    func testNothingSavedMeansNoEnvironmentAndSshIsUnchanged() {
        XCTAssertTrue(SSHPasswordStore.askpassEnvironment(for: alias).isEmpty)
    }

    /// Neither leg of the trip survives one: `security` reads the confirmation
    /// line-wise and ssh takes only the helper's first line, so accepting it would
    /// store a truncated password whose failure looks like a wrong one.
    func testAPasswordWithALineBreakIsRefused() {
        XCTAssertThrowsError(try SSHPasswordStore.save("two\nlines", for: alias)) { error in
            XCTAssertEqual(error as? SSHPasswordError, .passwordContainsNewline)
        }
        XCTAssertFalse(SSHPasswordStore.hasPassword(for: alias))
    }

    /// The existence check gates every SSH session launch on the main actor. A
    /// subprocess there is a visible freeze, so it must not be one.
    func testExistenceCheckIsFastEnoughForTheMainActor() throws {
        try SSHPasswordStore.save("hunter2", for: alias)
        let started = Date()
        for _ in 0..<50 { _ = SSHPasswordStore.hasPassword(for: alias) }
        let each = Date().timeIntervalSince(started) / 50
        XCTAssertLessThan(each, 0.005, "\(Int(each * 1000)) ms per check is a spawn, not a query")
    }

    func testRemovingSomethingThatIsNotThereStillReportsSuccess() {
        XCTAssertTrue(SSHPasswordStore.remove(for: alias))
    }

    func testEnvironmentForcesAskpassOverATerminal() throws {
        try SSHPasswordStore.save("hunter2", for: alias)
        let environment = SSHPasswordStore.askpassEnvironment(for: alias)
        // Without `force`, ssh prefers the tty and the saved password is ignored
        // on exactly the path that has one — a session.
        XCTAssertEqual(environment["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertEqual(environment["FYOLO_SSH_ALIAS"], alias)
        XCTAssertEqual(environment["SSH_ASKPASS"], try SSHPasswordStore.helperURL().path)
    }

    /// ssh silently ignores an askpass it cannot execute, which would look like the
    /// password was wrong rather than never sent.
    func testHelperIsExecutableAndOwnerOnly() throws {
        let url = try SSHPasswordStore.helperURL()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path))
        let permissions = try FileManager.default
            .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.int16Value, 0o700)
    }

    func testHelperHoldsNoSecret() throws {
        try SSHPasswordStore.save("hunter2", for: alias)
        let script = try String(contentsOf: try SSHPasswordStore.helperURL(), encoding: .utf8)
        XCTAssertFalse(script.contains("hunter2"))
    }

    func testSshSignsInWithTheSavedPassword() throws {
        guard let destination = ProcessInfo.processInfo.environment["FYOLO_TEST_SSH_URL"] else {
            throw XCTSkip("Set FYOLO_TEST_SSH_URL=user@host:port to run the live login")
        }
        let parsed = SSHConfigFile.parseDestination(destination)
        try SSHPasswordStore.save(
            ProcessInfo.processInfo.environment["FYOLO_TEST_SSH_PASSWORD"] ?? "hunter2",
            for: alias
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
            "-o", "NumberOfPasswordPrompts=1", "-o", "ConnectTimeout=10",
            "-p", parsed.port.isEmpty ? "22" : parsed.port,
            "\(parsed.user)@\(parsed.host)", "echo signed-in",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment.merge(SSHPasswordStore.askpassEnvironment(for: alias)) { _, new in new }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let text = String(
            data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(text.contains("signed-in"), "ssh printed: \(text)")
    }

    /// Runs the helper the way ssh would, and returns what ssh would read.
    private func helperOutput() throws -> String {
        let process = Process()
        process.executableURL = try SSHPasswordStore.helperURL()
        process.environment = SSHPasswordStore.askpassEnvironment(for: alias)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .newlines) ?? ""
    }
}
