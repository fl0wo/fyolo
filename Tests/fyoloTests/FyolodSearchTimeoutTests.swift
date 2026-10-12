import Darwin
import FyoloShared
import XCTest
@testable import fyolo

/// What a search does when the device accepts it and then says nothing.
///
/// This is not a hypothetical: unknown control operations are *dropped* by the
/// daemon rather than refused (`daemon.rs`, the `Control::Unknown` arm), so a
/// host that predates `fs.search` answers a search with silence on an open,
/// healthy connection. Without a bound the client parks a thread, a socket, and
/// on the SSH road a child process, for the life of the app.
///
/// The stub is a plain listening socket that completes the handshake and then
/// holds its end open — the one host that cannot be built out of a real daemon,
/// because a real daemon always answers.
final class FyolodSearchTimeoutTests: XCTestCase {
    private var socketPath = ""
    private var directory: URL?
    private var listener: Int32 = -1
    private var accepted: Int32 = -1
    private let handshaken = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Short path: `sun_path` is capped at 104 bytes.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tst-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        socketPath = directory.appendingPathComponent("fyolod.sock").path
        try XCTSkipIf(socketPath.utf8.count >= 104, "socket path must fit sun_path")

        listener = try listen(on: socketPath)
        setenv("FYOLOD_SOCK", socketPath, 1)
        serveOneSilentClient()
    }

    override func tearDownWithError() throws {
        release.signal()
        if accepted >= 0 { Darwin.close(accepted) }
        if listener >= 0 { Darwin.close(listener) }
        unsetenv("FYOLOD_SOCK")
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    /// The bound has to be wired into the request, not merely available: removing
    /// the `waitForReadable` call from `searchContents` hangs this test rather
    /// than failing it, which is the point — it is the hang that is the defect.
    func testASilentHostEndsTheSearchInsteadOfHangingForever() throws {
        var caught: Error?
        let finished = expectation(description: "the search gave up")
        DispatchQueue.global(qos: .userInitiated).async { [socketPath] in
            setenv("FYOLOD_SOCK", socketPath, 1)
            do {
                _ = try Fyolod.searchContents(
                    route: .local, root: NSTemporaryDirectory(), query: "anything",
                    limit: 400, idleTimeoutSeconds: 1)
            } catch {
                caught = error
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 20)

        guard case FyolodClientError.timedOut(let operation)? = caught else {
            return XCTFail("expected a timeout, got \(String(describing: caught))")
        }
        XCTAssertEqual(operation, "fs.search")
        XCTAssertEqual(handshaken.wait(timeout: .now()), .success,
                       "the stub must have been reached, or nothing was proven")
    }

    /// The stub grants `files` alone — a host from before `search_include`. It
    /// would drop the field and search everything, so a filtered search is
    /// refused before it is sent: the answer is immediate rather than the idle
    /// bound running out on a request the stub never read.
    func testAFilteredSearchIsNotSentToAHostThatCannotFilter() throws {
        var caught: Error?
        let finished = expectation(description: "the search was refused")
        DispatchQueue.global(qos: .userInitiated).async { [socketPath] in
            setenv("FYOLOD_SOCK", socketPath, 1)
            do {
                _ = try Fyolod.searchContents(
                    route: .local, root: NSTemporaryDirectory(), query: "anything",
                    include: ["*.ts"], limit: 400, idleTimeoutSeconds: 1)
            } catch {
                caught = error
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 20)

        XCTAssertEqual(caught as? DeviceFileError, .searchFilterUnsupported,
                       "got \(String(describing: caught))")
        XCTAssertEqual(handshaken.wait(timeout: .now()), .success,
                       "the stub must have been reached, or nothing was proven")
    }

    // MARK: - The stub host

    private func listen(on path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw FyolodClientError.connectionClosed }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { field in
            path.withCString { source in
                strlcpy(UnsafeMutableRawPointer(field).assumingMemoryBound(to: CChar.self),
                        source, capacity)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, size)
            }
        }
        guard bound == 0, Darwin.listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            throw FyolodClientError.connectionClosed
        }
        return descriptor
    }

    /// Accepts one client, answers its `hello` granting `files`, and then goes
    /// quiet without hanging up — the exact shape of a daemon too old to know
    /// the operation it was just asked for.
    private func serveOneSilentClient() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            accepted = client
            do {
                _ = try Fyolod.readFrame(client)
                let reply = """
                {"op":"hello_ok","proto":1,"host_id":"h_stub","host":"stub",
                 "client_id":"c_1","caps":["files"],"home":"/tmp"}
                """
                try Fyolod.writeFrame(client, kind: .control, payload: Data(reply.utf8))
                handshaken.signal()
            } catch {
                return
            }
            // Hold the connection open: closing it would end the client's read
            // with EOF, which is a different answer from the silence under test.
            release.wait()
        }
    }
}
