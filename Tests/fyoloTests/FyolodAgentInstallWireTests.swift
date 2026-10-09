import Foundation
import FyoloShared
import XCTest
@testable import fyolo

/// The `install_agents` reporter is spelled by the daemon's `Reporter` enum
/// (`fyolod/src/agent/install.rs`, internally tagged on `kind`). The two
/// sides drifted once — the daemon renamed its variants and the app kept
/// sending the old names, and every hook install in that release failed with
/// "unknown variant" — so the wire spelling is pinned here.
final class FyolodAgentInstallWireTests: XCTestCase {
    private func reporterJSON(_ reporter: Fyolod.AgentHookReporter) throws -> [String: Any] {
        let payload = try Fyolod.installAgentsPayload(
            agents: nil, hooks: .install, skills: .install, reporter: reporter)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        return try XCTUnwrap(object["reporter"] as? [String: Any])
    }

    func testThisMacIsSpelledTheDaemonsWay() throws {
        let reporter = try reporterJSON(.thisMac)
        XCTAssertEqual(reporter["kind"] as? String, "this_mac")
        XCTAssertEqual(reporter.count, 1, "the daemon resolves the command itself; nothing else travels")
    }

    func testADeviceIsSpelledTheDaemonsWay() throws {
        let reporter = try reporterJSON(.device)
        XCTAssertEqual(reporter["kind"] as? String, "device")
        XCTAssertEqual(reporter.count, 1)
    }

    /// The app used to send its release version for the daemon to stamp into
    /// every hook command, which rewrote every hook on every upgrade and left
    /// agents that verify their hook files refusing to run them. The stamp is
    /// the daemon's own schema constant now, and nothing about it travels.
    func testNoVersionTravelsWithAnInstall() throws {
        let payload = try Fyolod.installAgentsPayload(
            agents: nil, hooks: .install, skills: .install, reporter: .device)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertNil(object["hookVersion"])
        XCTAssertNil(object["hook_version"])
    }
}
