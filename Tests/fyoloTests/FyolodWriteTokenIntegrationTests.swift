import XCTest
import FyoloShared
@testable import fyolo

/// Two attachments on one session, against a real daemon.
///
/// The daemon hands the write token to the first attachment and to nobody
/// after it: a second device *looking* at a session must not mute the first,
/// and must not drag the one shared PTY to its own width behind that client's
/// back. `claim_writer` is what lets the token follow the device being *used*,
/// and this is the only test that exercises both halves of that against a real
/// daemon rather than against fixtures.
///
/// Opt-in on the same terms as the other daemon suites: set
/// `FYOLO_FYOLOD_TEST_BIN` to run it.
final class FyolodWriteTokenIntegrationTests: XCTestCase {
    private var binary = ""
    private var daemon: Process?
    private var socketDirectory: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let configured = ProcessInfo.processInfo.environment["FYOLO_FYOLOD_TEST_BIN"] ?? ""
        try XCTSkipIf(configured.isEmpty, "set FYOLO_FYOLOD_TEST_BIN to run this")
        binary = configured

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wtk-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketDirectory = directory
        let socket = directory.appendingPathComponent("fyolod.sock").path
        XCTAssertLessThan(socket.utf8.count, 104, "socket path must fit sun_path")
        setenv("FYOLOD_SOCK", socket, 1)

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
        try super.tearDownWithError()
    }

    private func link(_ name: String) -> FyolodSessionLink {
        FyolodSessionLink(
            sessionName: name,
            specification: Fyolod.CreateSpecification(
                cwd: NSTemporaryDirectory(),
                argv: ["/bin/cat"],
                env: [], rows: 24, cols: 80),
            rows: 24, cols: 80)
    }

    /// Waits for a link's writer state to reach `expected`, so the assertions
    /// describe the settled outcome rather than racing the event that carries it.
    private func waitForWriter(
        _ holder: WriterWatcher, _ expected: Bool, _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(5)
        while holder.isWriter != expected, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(holder.isWriter, expected, what, file: file, line: line)
    }

    /// Asserts a writer state *holds* through a settling window.
    ///
    /// `waitForWriter` cannot express "nothing happened": it is satisfied by the
    /// state the watcher already starts in, so it returns before the event that
    /// would have contradicted it has had time to arrive. Asserting that a
    /// second attachment did *not* take the token with a wait is therefore a
    /// test that passes against the exact behaviour it exists to catch — which
    /// is what the first draft of this file did.
    private func assertWriterHolds(
        _ holder: WriterWatcher, _ expected: Bool, _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            XCTAssertEqual(holder.isWriter, expected, what, file: file, line: line)
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// Waits for the link to say anything at all about its writer state. Every
    /// attachment announces its initial standing, so this is what tells "has not
    /// reported yet" apart from "reported that it is a reader".
    private func waitForFirstReport(
        _ holder: WriterWatcher, file: StaticString = #filePath, line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(5)
        while holder.reports == 0, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertGreaterThan(holder.reports, 0, "the attachment never reported", file: file, line: line)
    }

    /// `onWriter` fires on the main queue; the tests read it from there too.
    private final class WriterWatcher {
        var isWriter = false
        var reports = 0
    }

    func testTheWriteTokenFollowsTypingRatherThanAttaching() throws {
        let name = "write-token-\(UUID().uuidString.prefix(8))"

        let mac = link(name)
        let macWriter = WriterWatcher()
        mac.onWriter = { macWriter.isWriter = $0; macWriter.reports += 1 }
        mac.start()
        defer { mac.detach() }
        waitForWriter(macWriter, true, "the first attachment holds the token")

        // A phone opens the same session. Looking is not taking.
        let phone = link(name)
        let phoneWriter = WriterWatcher()
        phone.onWriter = { phoneWriter.isWriter = $0; phoneWriter.reports += 1 }
        phone.start()
        defer { phone.detach() }
        waitForFirstReport(phoneWriter)
        assertWriterHolds(phoneWriter, false, "a second attachment arrives as a reader")
        assertWriterHolds(macWriter, true, "and leaves the first one writing")

        // The phone's user types. Before `claim_writer` this input was simply
        // refused by the daemon and the phone stayed mute.
        phone.send(Data("echo\n".utf8))
        waitForWriter(phoneWriter, true, "typing on the phone takes the token")
        waitForWriter(macWriter, false, "and the Mac is told it lost it")

        // And back again, so the token is genuinely mobile rather than
        // one-directional.
        mac.send(Data("echo\n".utf8))
        waitForWriter(macWriter, true, "typing on the Mac takes it back")
        waitForWriter(phoneWriter, false, "the phone yields in turn")

        // The other half of the same rule: a deliberate claim moves the token
        // without a keystroke, which is what a phone opening a session sends.
        phone.claimWriter()
        waitForWriter(phoneWriter, true, "an explicit claim takes the token")
        waitForWriter(macWriter, false, "and the Mac is told it lost it")
    }
}
