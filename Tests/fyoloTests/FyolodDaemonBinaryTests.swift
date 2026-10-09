import XCTest
import FyoloShared
@testable import fyolo

/// `Fyolod.developmentDaemonCandidates` — the checkout half of daemon
/// resolution. The bundle half cannot be tested from `swift test` (the test
/// process has no `.app`, which is exactly the case the checkout half exists
/// for), so what is pinned here is the fallback that must keep a developer
/// working and, above all, that resolution is anchored at the running binary
/// rather than at the working directory: a Finder-launched app has cwd `/`, and
/// the previous fallback resolved `/fyolod/target/debug/fyolod` there — the
/// reason no released build could start a daemon.
final class FyolodDaemonBinaryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fyolod-resolution-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeCheckout(at directory: URL) throws {
        let daemon = directory.appendingPathComponent("fyolod")
        try FileManager.default.createDirectory(at: daemon, withIntermediateDirectories: true)
        try Data("[package]\nname = \"fyolod\"\n".utf8)
            .write(to: daemon.appendingPathComponent("Cargo.toml"))
    }

    /// The `.build/<triple>/debug/fyolo` case: a bare SwiftPM binary sitting
    /// three levels below the checkout it was built in.
    func testFindsTheCheckoutAboveASwiftPMBinary() throws {
        try makeCheckout(at: root)
        let binaryDirectory = root.appendingPathComponent(".build/arm64-apple-macosx/debug")
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)

        let candidates = Fyolod.developmentDaemonCandidates(near: binaryDirectory)

        XCTAssertEqual(candidates, [
            root.appendingPathComponent("fyolod/target/release/fyolod").path,
            root.appendingPathComponent("fyolod/target/debug/fyolod").path,
        ], "release before debug, both anchored at the checkout, not at the cwd")
    }

    /// The `.app`-assembled-at-the-repo-root case: `Contents/MacOS` is two
    /// levels down, and the daemon in the checkout is the right answer when the
    /// bundle carries none (a dev build made without a Rust toolchain).
    func testFindsTheCheckoutAboveAnAppBundle() throws {
        try makeCheckout(at: root)
        let binaryDirectory = root.appendingPathComponent("fyolo-dev.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)

        XCTAssertEqual(Fyolod.developmentDaemonCandidates(near: binaryDirectory).first,
                       root.appendingPathComponent("fyolod/target/release/fyolod").path)
    }

    /// The shipped case: an app in /Applications has no checkout above it, and
    /// answering with a path anyway is what produced `/fyolod/target/debug/fyolod`.
    func testAnswersNothingWithNoCheckoutAbove() throws {
        let binaryDirectory = root.appendingPathComponent("Applications/fyolo.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)

        XCTAssertEqual(Fyolod.developmentDaemonCandidates(near: binaryDirectory), [])
    }

    /// The walk stops rather than running to `/`: a `fyolod/Cargo.toml` far
    /// enough above the binary is somebody else's checkout, not this build's.
    func testStopsWalkingBeforeTheFilesystemRoot() throws {
        try makeCheckout(at: root)
        let deep = root.appendingPathComponent("a/b/c/d/e/f/g/h/i")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

        XCTAssertEqual(Fyolod.developmentDaemonCandidates(near: deep), [])
    }

    /// The development override outranks everything, including a bundled daemon
    /// — it is what a developer sets to run a build they just made.
    func testEnvironmentOverrideWins() throws {
        let override = root.appendingPathComponent("my-fyolod").path
        setenv("FYOLO_FYOLOD_BIN", override, 1)
        defer { unsetenv("FYOLO_FYOLOD_BIN") }

        XCTAssertEqual(Fyolod.daemonBinaryPath(), override)
    }

    // MARK: - Channel scoping

    /// The dev build and the release app must not land on one socket. The socket
    /// is the rendezvous for a whole session table — in Rust `state_dir()` is the
    /// socket's own directory, so `host.id` and the roster hang off it too — and
    /// sharing it makes the two channels **one device**: each is handed the
    /// other's sessions to draw under Also Running, and each can kill them.
    func testTheDevChannelDerivesItsOwnSocket() {
        let environment = ["TMPDIR": "/var/folders/xx/T/"]
        let release = Fyolod.socketPath(channelSuffix: "", environment: environment)
        let dev = Fyolod.socketPath(channelSuffix: "-dev", environment: environment)

        XCTAssertNotEqual(release, dev)
        XCTAssertTrue(dev.hasSuffix("-dev/fyolod.sock"), dev)
        XCTAssertEqual(URL(fileURLWithPath: release).deletingLastPathComponent().path + "-dev",
                       URL(fileURLWithPath: dev).deletingLastPathComponent().path)
    }

    /// The release channel's suffix is empty, so its path is byte-identical to
    /// the one it had before channels were scoped. Anything else would strand
    /// every session running under a shipped fyolo the day this ships.
    func testTheReleaseChannelSocketIsUnchanged() {
        let path = Fyolod.socketPath(channelSuffix: "",
                                      environment: ["TMPDIR": "/var/folders/xx/T"])

        XCTAssertEqual(path, "/var/folders/xx/T/fyolod-\(getuid())/fyolod.sock")
    }

    /// `FYOLOD_SOCK` still outranks the channel. It is how the tests and a
    /// deliberate side-by-side daemon isolate, and a channel must not quietly
    /// redirect a path the user pinned by hand.
    func testAPinnedSocketOutranksTheChannel() {
        let path = Fyolod.socketPath(
            channelSuffix: "-dev",
            environment: ["FYOLOD_SOCK": "/tmp/pinned/fyolod.sock", "TMPDIR": "/var/folders/xx/T"])

        XCTAssertEqual(path, "/tmp/pinned/fyolod.sock")
    }

    /// `$XDG_RUNTIME_DIR` is the preferred base on the systems that set it, and
    /// it carries the channel too — otherwise the scoping holds on macOS and
    /// silently does not on a Linux box reached over SSH.
    func testTheRuntimeDirectoryBaseCarriesTheChannel() {
        let path = Fyolod.socketPath(channelSuffix: "-dev",
                                      environment: ["XDG_RUNTIME_DIR": "/run/user/501"])

        XCTAssertEqual(path, "/run/user/501/fyolod-dev/fyolod.sock")
    }

    /// What the app hands the daemon as `FYOLO_CHANNEL`. The release channel is
    /// named rather than left empty: the daemon may be spawned from a process
    /// that already has the variable set, and an unset key would let that value
    /// through to redirect it.
    func testTheReleaseChannelIsNamedNotOmitted() {
        XCTAssertFalse(Fyolod.channelName.isEmpty)
    }

    /// The durable-state mirror of fyolod/src/paths.rs: per channel, under
    /// Application Support — and back beside the socket the moment
    /// `FYOLOD_SOCK` pins one, so a test daemon's token never shadows the
    /// real one's.
    func testDurableStateDirectoryIsChannelScoped() {
        let release = Fyolod.durableStateDirectory(
            channelSuffix: "", environment: [:], home: "/Users/u")
        let dev = Fyolod.durableStateDirectory(
            channelSuffix: "-dev", environment: [:], home: "/Users/u")
        XCTAssertEqual(release, "/Users/u/Library/Application Support/fyolo")
        XCTAssertEqual(dev, "/Users/u/Library/Application Support/fyolo-dev")
    }

    func testPinnedSocketKeepsDurableStateBesideIt() {
        let pinned = Fyolod.durableStateDirectory(
            channelSuffix: "",
            environment: ["FYOLOD_SOCK": "/tmp/test-daemon/fyolod.sock"],
            home: "/Users/u")
        XCTAssertEqual(pinned, "/tmp/test-daemon")
    }

    /// A shipped `.app` ignores a pinned socket and stays on its channel.
    ///
    /// Every fyolo session exports `FYOLOD_SOCK`, and macOS `open` hands the
    /// caller's environment to the app it launches, so without this a dev build
    /// started from a release session bound to the *release* daemon while
    /// keeping its dev bundle id, dev state directory and dev companion port.
    /// Two apps then shared one session table, each drawing and able to kill
    /// what the other was running — and every measurement taken against that
    /// app was of the wrong process.
    func testABundleIgnoresAPinnedSocketAndStaysOnItsChannel() {
        let leaked = ["FYOLOD_SOCK": "/var/tmp/fyolod-501/fyolod.sock",
                      "TMPDIR": "/var/folders/xx/T"]

        XCTAssertEqual(
            Fyolod.socketPath(channelSuffix: "-dev", environment: leaked, bundled: true),
            "/var/folders/xx/T/fyolod-\(getuid())-dev/fyolod.sock")
        XCTAssertEqual(
            Fyolod.socketPath(channelSuffix: "-dev", environment: leaked, bundled: false),
            "/var/tmp/fyolod-501/fyolod.sock",
            "the unbundled case — swift run and this test suite — still honours the pin")
    }

    /// The durable state directory follows the socket, so it has to answer the
    /// bundle question the same way. Disagreeing would put the pairing token
    /// and `host.id` beside one daemon while the app talked to another.
    func testABundleKeepsDurableStateOnItsChannelDespiteAPinnedSocket() {
        let leaked = ["FYOLOD_SOCK": "/var/tmp/fyolod-501/fyolod.sock"]

        XCTAssertEqual(
            Fyolod.durableStateDirectory(
                channelSuffix: "-dev", environment: leaked, home: "/Users/u", bundled: true),
            "/Users/u/Library/Application Support/fyolo-dev")
        XCTAssertEqual(
            Fyolod.durableStateDirectory(
                channelSuffix: "-dev", environment: leaked, home: "/Users/u", bundled: false),
            "/var/tmp/fyolod-501")
    }
}
