import XCTest
@testable import fyolo

final class RemoteTunnelTests: XCTestCase {
    func testOriginValueDropsPathFromPublishedAddress() {
        XCTAssertEqual(
            RemoteTunnelService.originValue(of: "https://relay.example.com/fyolo"),
            "https://relay.example.com")
    }

    func testOriginValueKeepsNonDefaultPort() {
        XCTAssertEqual(
            RemoteTunnelService.originValue(of: "https://relay.example.com:8443/fyolo"),
            "https://relay.example.com:8443")
    }

    /// The drop-in is the shape `fyolod/DEPLOY.md` documents for pinning the
    /// bind in the unit: both variables, under `[Service]`, and nothing that
    /// would make it a second writer of the unit file itself.
    func testListenerDropInCarriesBindAndOriginOnly() {
        let text = RemoteTunnelService.listenerDropInText(
            origin: "https://box.example.net", port: 8790)
        XCTAssertEqual(text, """
            [Service]
            Environment="FYOLOD_WSS=127.0.0.1:8790"
            Environment="FYOLOD_WSS_ORIGIN=https://box.example.net"

            """)
        XCTAssertFalse(text.contains("ExecStart"))
        XCTAssertFalse(text.contains("Restart="))
    }

    /// A `%` in an origin would otherwise be read as a specifier and the unit
    /// would fail to load — with an error about the drop-in, on the box, that
    /// nothing on screen would repeat.
    func testListenerDropInEscapesSpecifiers() {
        let text = RemoteTunnelService.listenerDropInText(
            origin: "https://100%.example.net", port: 8790)
        XCTAssertTrue(text.contains("Environment=\"FYOLOD_WSS_ORIGIN=https://100%%.example.net\""))
    }

    func testListenerOriginIsReadFromShownEnvironment() {
        XCTAssertEqual(
            RemoteTunnelService.listenerOrigin(
                fromEnvironment: "FYOLOD_WSS=127.0.0.1:8790 FYOLOD_WSS_ORIGIN=https://box.example.net\n"),
            "https://box.example.net")
        XCTAssertEqual(
            RemoteTunnelService.listenerOrigin(
                fromEnvironment: "FYOLOD_WSS_ORIGIN=\"https://box.example.net\""),
            "https://box.example.net")
    }

    /// No drop-in means no answer, not an empty one: `pair` must then fall
    /// through to the daemon's own `wss.origin`.
    func testListenerOriginIsAbsentWithoutADropIn() {
        XCTAssertNil(RemoteTunnelService.listenerOrigin(fromEnvironment: "\n"))
        XCTAssertNil(RemoteTunnelService.listenerOrigin(fromEnvironment: "FYOLOD_WSS=127.0.0.1:8790"))
    }
}
