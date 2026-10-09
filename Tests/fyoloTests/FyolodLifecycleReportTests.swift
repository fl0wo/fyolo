import Foundation
import FyoloShared
import XCTest
@testable import fyolo

/// `fyolod deploy --json` is the one document the app reads a machine's
/// lifecycle state from. These pin the field names the daemon writes
/// (`fyolod/src/lifecycle.rs`, `Report` and `Outcome`) so a rename on either
/// side fails here rather than as a machine that reads as broken.
final class FyolodLifecycleReportTests: XCTestCase {
    func testCurrentCarriesTheVersionAndIdentity() throws {
        let report = try Fyolod.LifecycleReport.decode(Data("""
        {"node":"ukvps","desired":"0.44.0+1600","state":"current",
         "version":"0.44.0+1600","host_id":"h_1","newer":false}
        """.utf8))
        XCTAssertEqual(report.state, .current)
        XCTAssertEqual(report.version, "0.44.0+1600")
        XCTAssertEqual(report.hostId, "h_1")
        XCTAssertEqual(report.newer, false)
    }

    func testStagedNamesTheSessionsThatKeptTheOldDaemonUp() throws {
        let report = try Fyolod.LifecycleReport.decode(Data("""
        {"node":"ukvps","desired":"0.44.0+1600","state":"staged",
         "version":"0.44.0+1600","daemon":"0.43.0+1500",
         "busy":[{"id":"1","name":"claude","command":"claude","status":"working",
                  "attached":0,"alive":true}]}
        """.utf8))
        XCTAssertEqual(report.state, .staged)
        XCTAssertEqual(report.daemon, "0.43.0+1500")
        XCTAssertEqual(report.busy?.map(\.name), ["claude"])
        XCTAssertEqual(report.busy?.first?.status, "working")
    }

    func testUnhealthySaysWhetherItRolledBack() throws {
        let report = try Fyolod.LifecycleReport.decode(Data("""
        {"node":"ukvps","desired":"0.44.0+1600","state":"unhealthy",
         "message":"no protocol reply within 10s (Exec format error)","rolled_back":true}
        """.utf8))
        XCTAssertEqual(report.state, .unhealthy)
        XCTAssertEqual(report.rolledBack, true)
        XCTAssertEqual(report.message, "no protocol reply within 10s (Exec format error)")
    }

    /// A state this build has never heard of must fail loudly, not decode as
    /// something it is not.
    func testAnUnknownStateDoesNotDecode() {
        XCTAssertThrowsError(try Fyolod.LifecycleReport.decode(Data("""
        {"node":"ukvps","desired":"0.44.0+1600","state":"rebooting"}
        """.utf8)))
    }
}
