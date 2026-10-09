import SwiftUI
import XCTest
@testable import fyolo

/// The mark a row carries for the machine it runs on (`DeviceMark`).
///
/// The invariant worth pinning is the one the whole device vocabulary rests on:
/// a mark follows the *machine*, not the road taken to it. Keyed by alias, one
/// box reached over a LAN name, a WAN name and a tailnet name would carry three
/// different marks — worse than no mark at all, because the cue would then be
/// actively misleading.
///
/// It used to be pinned about a hue. The hue is gone (a workspace belongs to one
/// machine, so it was the same colour repeated down the column); the identity
/// rule it protected is not, because the mark now has to decide whether a row's
/// device *is* the device being shown before it may claim to know anything live
/// about it.
@MainActor
final class DeviceMarkTests: XCTestCase {
    private static let ready = DeviceSessionsState.ready(DeviceSessions(live: [], tombstones: []))

    /// Two aliases that resolved to one `host_id` are one machine, so a reply
    /// from that machine speaks for a row reached by either name.
    func testOneDeviceReachedByTwoAliasesIsOneMachine() {
        let lan = KnownDevice(alias: "vps-lan", deviceID: "device-a")
        let tailnet = KnownDevice(alias: "vps-tailnet", deviceID: "device-a")

        XCTAssertEqual(
            DeviceMark.mark(for: lan, current: tailnet, state: .failed("timed out")),
            .unreachable("timed out"),
            "the same machine under another name is still the machine that answered")
    }

    /// This Mac is the absence of a mark, whatever the current device is doing.
    func testThisMacCarriesNoMark() {
        XCTAssertEqual(
            DeviceMark.mark(for: .thisMac, current: .thisMac, state: .failed("timed out")), .here)
        XCTAssertEqual(
            DeviceMark.mark(
                for: .thisMac, current: KnownDevice(alias: "ukvps", deviceID: nil),
                state: .loading),
            .here)
    }

    /// Liveness is claimed only for the device being shown. Another machine gets
    /// the plain elsewhere mark rather than the current one's state, because
    /// nothing has asked it.
    func testAnotherMachineIsNotGivenThisOnesState() {
        let shown = KnownDevice(alias: "ukvps", deviceID: "device-a")
        let other = KnownDevice(alias: "boxlit", deviceID: "device-b")

        XCTAssertEqual(DeviceMark.mark(for: other, current: shown, state: .loading), .elsewhere)
        XCTAssertEqual(
            DeviceMark.mark(for: other, current: shown, state: .failed("refused")), .elsewhere)
    }

    /// The three things the shown device can be, once it is not this Mac.
    func testTheShownDeviceReportsWhatItSaid() {
        let device = KnownDevice(alias: "ukvps", deviceID: "device-a")

        XCTAssertEqual(DeviceMark.mark(for: device, current: device, state: .loading), .reaching)
        XCTAssertEqual(
            DeviceMark.mark(for: device, current: device, state: .failed("Permission denied")),
            .unreachable("Permission denied"))
        XCTAssertEqual(DeviceMark.mark(for: device, current: device, state: Self.ready), .elsewhere)
        XCTAssertEqual(
            DeviceMark.mark(for: device, current: device, state: .unavailable), .elsewhere,
            "no session host to ask is not the machine refusing")
    }

    /// Before any handshake the alias is all there is, and it still has to
    /// resolve — a machine reached by name alone is the machine on screen.
    func testAnUnreachedAliasStillMatchesByName() {
        let device = KnownDevice(alias: "newbox", deviceID: nil)

        XCTAssertEqual(DeviceMark.mark(for: device, current: device, state: .loading), .reaching)
    }

    /// The case that shipped wrong once: a plain `ssh` shell and a durable
    /// fyolod session on the *same* box, sitting next to each other in one
    /// section. An `ssh` terminal never handshakes, so it carries no `deviceID`;
    /// `KnownDevice.running` resolves the alias first, which is what keeps the
    /// two rows one machine.
    func testAnSSHShellAndAFyolodSessionOnOneBoxAreOneMachine() throws {
        var ssh = Session(title: "SSH Shell", agent: .terminal)
        ssh.sshHost = "ukvps"
        var durable = Session(title: "Terminal 1", agent: .terminal)
        durable.fyolodRemoteHost = "ukvps"
        durable.deviceID = "h_2dd9"
        let registry: (String) -> String? = { $0 == "ukvps" ? "h_2dd9" : nil }

        let sshDevice = try XCTUnwrap(KnownDevice.running(ssh, resolvingAlias: registry))
        let durableDevice = try XCTUnwrap(KnownDevice.running(durable, resolvingAlias: registry))

        XCTAssertEqual(sshDevice.deviceID, "h_2dd9", "the alias resolves to the machine")
        XCTAssertEqual(
            DeviceMark.mark(for: sshDevice, current: durableDevice, state: .loading), .reaching)
    }

    /// A session on this Mac has no machine to mark.
    func testALocalSessionHasNoDevice() {
        XCTAssertNil(KnownDevice.running(Session(title: "Terminal 1"), resolvingAlias: { _ in nil }))
    }
}
