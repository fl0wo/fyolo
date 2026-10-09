import XCTest
import FyoloShared
@testable import fyolo

/// What happens when the transport dies under a live session.
///
/// Every other daemon suite is a happy path: start, attach, work, tear down.
/// None of them kills the daemon, and that is the one failure mode with no
/// fallback left now that the in-process backend is gone — the daemon is the
/// only thing holding the PTY.
///
/// The distinction under test is that a broken pipe is not an exit. The child
/// is almost certainly still running, which is the entire point of it living in
/// a daemon; reporting an exit for it invents a status the process never
/// produced, and hands that invented status to the exit policy.
///
/// Opt-in on the same terms as the other daemon suites: set
/// `FYOLO_FYOLOD_TEST_BIN` to run these.
@MainActor
final class FyolodFaultIntegrationTests: XCTestCase {
    private var binary = ""
    private var daemon: Process?
    private var socketDirectory: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let configured = ProcessInfo.processInfo.environment["FYOLO_FYOLOD_TEST_BIN"] ?? ""
        try XCTSkipIf(configured.isEmpty, "set FYOLO_FYOLOD_TEST_BIN to run this")
        binary = configured

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flt-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketDirectory = directory
        let socket = directory.appendingPathComponent("fyolod.sock").path
        XCTAssertLessThan(socket.utf8.count, 104, "socket path must fit sun_path")
        setenv("FYOLOD_SOCK", socket, 1)
        // A link whose transport dies now reconnects on its own, and the local
        // transport revives a dead daemon while it is at it — so a suite that
        // kills daemons would leave one running behind every test. These tests
        // start their own daemon; nothing here needs the client to.
        setenv("FYOLO_FYOLOD_BIN", "/nonexistent/fyolod", 1)
        try startDaemon(socket: socket)
    }

    private func startDaemon(socket: String) throws {
        let serve = Process()
        serve.executableURL = URL(fileURLWithPath: binary)
        serve.arguments = ["serve"]
        serve.environment = ProcessInfo.processInfo.environment.merging(
            ["FYOLOD_SOCK": socket]) { _, new in new }
        serve.standardOutput = FileHandle.nullDevice
        serve.standardError = FileHandle.nullDevice
        try serve.run()
        daemon = serve

        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: socket), Date() < deadline {
            usleep(50_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket), "daemon never bound")
    }

    override func tearDownWithError() throws {
        daemon?.terminate()
        daemon?.waitUntilExit()
        if let socketDirectory {
            try? FileManager.default.removeItem(at: socketDirectory)
        }
        unsetenv("FYOLOD_SOCK")
        unsetenv("FYOLO_FYOLOD_BIN")
        try super.tearDownWithError()
    }

    private func link(_ name: String, argv: [String]) -> FyolodSessionLink {
        FyolodSessionLink(
            sessionName: name,
            specification: Fyolod.CreateSpecification(
                cwd: NSTemporaryDirectory(), argv: argv, env: [], rows: 24, cols: 80),
            rows: 24, cols: 80)
    }

    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    /// Killing the daemon under an attached session must not look like the
    /// session exiting. Before the split this delivered `exit 1` — a status the
    /// child never produced, which then went to the exit policy and parked the
    /// pane over an error with no error output behind it.
    func testKillingTheDaemonIsNotReportedAsAnExit() throws {
        var exits: [Int32] = []
        var lostConnection = false

        let session = link("fault-\(UUID().uuidString.prefix(8))",
                           argv: ["/bin/sh", "-c", "while :; do sleep 3600; done"])
        session.onExit = { code, _, _ in exits.append(code) }
        session.onConnectionLost = { _ in lostConnection = true }
        session.start()
        defer { session.detach() }

        XCTAssertTrue(
            waitUntil(5) { session.latestInformation != nil || lostConnection },
            "the fixture never attached")

        // SIGKILL, not `terminate()`. A SIGTERM is caught and the daemon drains:
        // it kills each session and reports the real `session_exited` (status
        // 137) before closing the socket, which is correct and is *not* the
        // case under test. A transport failure is the daemon never getting to
        // say anything — the client sees EOF and nothing else, exactly as a cut
        // network or a broken SSH pipe looks.
        if let pid = daemon?.processIdentifier { kill(pid, SIGKILL) }
        daemon?.waitUntilExit()
        daemon = nil

        XCTAssertTrue(waitUntil(5) { lostConnection }, "the dead transport was never reported")
        XCTAssertTrue(
            exits.isEmpty,
            "a broken transport was reported as the session exiting with \(exits)")
    }

    /// The other direction, so the split does not simply mute exits: a session
    /// that genuinely ends still reports its own status, and does not also
    /// arrive as a disconnection when its stream closes behind it.
    func testAGenuineExitIsStillAnExit() throws {
        var exits: [Int32] = []
        var lostConnection = false

        let session = link("exit-\(UUID().uuidString.prefix(8))",
                           argv: ["/bin/sh", "-c", "exit 7"])
        session.onExit = { code, _, _ in exits.append(code) }
        session.onConnectionLost = { _ in lostConnection = true }
        session.start()
        defer { session.detach() }

        XCTAssertTrue(waitUntil(10) { !exits.isEmpty }, "the exit never arrived")
        XCTAssertEqual(exits, [7], "the child's own status, once")

        // The daemon closes the stream right after the exit; that EOF must not
        // be re-reported as a lost connection.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(lostConnection, "an ordinary exit was also reported as a disconnection")
    }

    /// Attaching to a daemon that is not there must not invent an exit either.
    ///
    /// This is the arm that made the first version of this fix circular: the
    /// connection-lost handler retired the cached surface, `TerminalPane`'s body
    /// calls `surface(for:)` so the *next render* rebuilt it — not the next
    /// deliberate selection — and `start()` failing against the still-dead
    /// transport delivered the same fabricated `exit 1` through its own catch.
    /// Reaching the daemon and losing it are one class of event, and neither
    /// carries a status.
    func testAttachingWithNoDaemonIsNotReportedAsAnExit() throws {
        // Point the client at a socket path nothing is listening on, which is
        // what a rebuild over a broken transport actually meets.
        let dead = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gone-\(UUID().uuidString.prefix(8)).sock").path
        setenv("FYOLOD_SOCK", dead, 1)
        defer { setenv("FYOLOD_SOCK", socketDirectory?.appendingPathComponent("fyolod.sock").path ?? "", 1) }

        var exits: [Int32] = []
        var lostConnection = false
        let session = link("norun-\(UUID().uuidString.prefix(8))", argv: ["/bin/sh"])
        session.onExit = { code, _, _ in exits.append(code) }
        session.onConnectionLost = { _ in lostConnection = true }
        session.start()
        defer { session.detach() }

        XCTAssertTrue(waitUntil(10) { lostConnection || !exits.isEmpty }, "nothing was reported")
        XCTAssertTrue(
            exits.isEmpty,
            "an unreachable daemon was reported as the session exiting with \(exits)")
        XCTAssertTrue(lostConnection, "an unreachable daemon was never reported at all")
    }

    /// A daemon that is reachable and says no is a third outcome, not a lost
    /// connection.
    ///
    /// Widening the attach-failure arm to "connection lost" swept this up with
    /// it, so a spawn the device refused — a cwd that does not exist — told the
    /// user their session was "still running there". Nothing was ever running.
    /// That is a different lie from the one this file exists to remove.
    func testARefusedSpawnIsNotALostConnection() throws {
        var exits: [Int32] = []
        var lostConnection = false
        var refusal: String?

        let missing = NSTemporaryDirectory() + "definitely-not-here-\(UUID().uuidString)"
        let session = FyolodSessionLink(
            sessionName: "refused-\(UUID().uuidString.prefix(8))",
            specification: Fyolod.CreateSpecification(
                cwd: missing, argv: ["/bin/sh"], env: [], rows: 24, cols: 80),
            rows: 24, cols: 80)
        session.onExit = { code, _, _ in exits.append(code) }
        session.onConnectionLost = { _ in lostConnection = true }
        session.onStartRefused = { refusal = $0 }
        session.start()
        defer { session.detach() }

        XCTAssertTrue(
            waitUntil(10) { refusal != nil || lostConnection || !exits.isEmpty },
            "the daemon's refusal was never reported at all")
        XCTAssertNotNil(refusal, "a refusal was reported as something else")
        XCTAssertFalse(
            lostConnection,
            "a reachable daemon that refused was reported as a lost connection")
        XCTAssertTrue(exits.isEmpty, "a refusal was reported as an exit \(exits)")
        XCTAssertFalse(
            refusal?.isEmpty ?? true,
            "the refusal carried no reason, so the pane can only say it failed")
        // Not merely non-empty: the generic "attach was not acknowledged" this
        // arm used to throw passes that and names nothing. What the pane prints
        // has to be the device's own account of why — the only part of it the
        // user can act on — so the reply's error payload must survive the throw.
        XCTAssertNotEqual(
            refusal, "attach was not acknowledged",
            "the daemon's reason was discarded, so the pane can only say it failed")
    }

    /// Nobody should have to ask. A transport that dies under a live session is
    /// the link's problem to solve, and it solves it: a fast burst of attach
    /// attempts, then a slow heartbeat, until the box answers again.
    ///
    /// Before this, the pane dead-ended — it told the user to close the session
    /// and open it again, which is the *destroy* verb, and which did not work
    /// anyway because a re-selected session is handed the same cached surface.
    /// Quitting the whole app was the only way back to a session that had never
    /// stopped running (#658).
    func testTheLinkReattachesItselfWhenTheDaemonComesBack() throws {
        var exits: [Int32] = []
        var attempts: [Int] = []
        var reattached = false

        let socket = try XCTUnwrap(socketDirectory).appendingPathComponent("fyolod.sock").path
        let session = link("heal-\(UUID().uuidString.prefix(8))",
                           argv: ["/bin/sh", "-c", "while :; do sleep 3600; done"])
        session.onExit = { code, _, _ in exits.append(code) }
        session.onConnectionLost = { attempts.append($0) }
        session.onReattached = { reattached = true }
        session.start()
        defer { session.killAndClose() }
        XCTAssertTrue(waitUntil(5) { session.latestInformation != nil }, "never attached")

        if let pid = daemon?.processIdentifier { kill(pid, SIGKILL) }
        daemon?.waitUntilExit()
        daemon = nil
        XCTAssertTrue(waitUntil(5) { !attempts.isEmpty }, "the dead transport was never reported")
        XCTAssertEqual(attempts.first, 1, "the first report must be the first failed attempt")

        // Nothing touches the link from here: no new surface, no relaunch, no
        // user. The daemon simply comes back, and the retry already on the
        // clock is what finds it.
        try startDaemon(socket: socket)
        XCTAssertTrue(waitUntil(20) { reattached }, "the link never reattached itself")
        XCTAssertTrue(waitUntil(5) { session.latestInformation != nil },
                      "reattached without a live session behind it")
        XCTAssertTrue(exits.isEmpty, "a reconnect invented an exit \(exits)")
    }

    /// A deliberate teardown ends the retrying too. Without this the loop would
    /// outlive the thing it serves: a session the user closed, or an app that
    /// has already quit, dialling a box every 30 seconds forever.
    func testDetachStopsTheReconnectLoop() throws {
        var attempts: [Int] = []
        let session = link("quiet-\(UUID().uuidString.prefix(8))",
                           argv: ["/bin/sh", "-c", "while :; do sleep 3600; done"])
        session.onConnectionLost = { attempts.append($0) }
        session.start()
        XCTAssertTrue(waitUntil(5) { session.latestInformation != nil }, "never attached")

        session.detach()
        if let pid = daemon?.processIdentifier { kill(pid, SIGKILL) }
        daemon?.waitUntilExit()
        daemon = nil

        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertTrue(attempts.isEmpty, "a detached link kept reconnecting \(attempts)")
    }

    /// The session outlives the connection, which is the claim the split rests
    /// on: after the daemon comes back, the same name resolves to the same
    /// still-running process rather than spawning a replacement.
    func testTheSessionSurvivesTheConnectionAndIsReattachable() throws {
        let name = "survive-\(UUID().uuidString.prefix(8))"
        let first = link(name, argv: ["/bin/sh", "-c", "while :; do sleep 3600; done"])
        var lostConnection = false
        first.onConnectionLost = { _ in lostConnection = true }
        first.start()
        XCTAssertTrue(waitUntil(5) { first.latestInformation != nil }, "never attached")
        let originalPid = first.latestInformation?.pid
        XCTAssertNotNil(originalPid)

        // Sever the client's socket without stopping the daemon: the process
        // keeps running and the name stays resolvable.
        first.detach()
        XCTAssertFalse(lostConnection, "a deliberate detach is not a lost connection")

        let second = link(name, argv: [])
        second.start()
        defer { second.killAndClose() }
        XCTAssertTrue(waitUntil(5) { second.latestInformation != nil }, "never reattached")
        XCTAssertEqual(
            second.latestInformation?.pid, originalPid,
            "reattaching spawned a replacement instead of resolving the surviving session")
    }
}
