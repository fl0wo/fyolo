import FyoloShared
import XCTest
@testable import fyolo

/// The test-run plane's wire shapes, decoded from what fyolod actually wrote for
/// a real Vitest run: a failed assertion, a file that failed to load, and an
/// unhandled rejection.
final class FyolodTestRunsWireTests: XCTestCase {
    private let summary = #"""
    {"id":"5dbacacf-103a-4a3b-b6a0-dc45c47978c2","root":"/repo","state":"failed","started_at":1792489814854,"duration_ms":96,"counts":{"passed":4,"failed":1,"skipped":2},"files_total":3,"files_done":3,"package":"fx5","argv":["run","src/math","src/strings","src/broken"]}
    """#

    func testRunChangedEventDecodes() throws {
        let event = #"{"ev":"test_run_changed","resource":"tests:/repo","seq":7,"run":\#(summary)}"#
        let decoded = try Fyolod.testRunsDecoder().decode(
            Fyolod.WireTestRunChanged.self, from: Data(event.utf8))
        XCTAssertEqual(decoded.seq, 7)
        XCTAssertEqual(decoded.run.state, "failed")
        XCTAssertFalse(decoded.run.isRunning)
        XCTAssertEqual(decoded.run.counts, Fyolod.TestCounts(passed: 4, failed: 1, skipped: 2))
        XCTAssertEqual(decoded.run.filesDone, 3)
        XCTAssertEqual(decoded.run.argv, ["run", "src/math", "src/strings", "src/broken"])
        XCTAssertNil(decoded.run.commandId)
        XCTAssertEqual(decoded.run.startedDate.timeIntervalSince1970, 1_792_489_814.854, accuracy: 0.001)
    }

    /// A live run's first report carries little, and a newer daemon may add
    /// fields. Neither may sink the row.
    func testSparseAndNewerSummariesDecode() throws {
        let sparse = #"{"id":"a","root":"/repo","state":"running","started_at":1,"from_the_future":true}"#
        let run = try Fyolod.testRunsDecoder().decode(Fyolod.TestRunSummary.self, from: Data(sparse.utf8))
        XCTAssertTrue(run.isRunning)
        XCTAssertEqual(run.counts, Fyolod.TestCounts())
        XCTAssertEqual(run.argv, [])
    }

    func testDetailDecodesEveryFailureKind() throws {
        let detail = #"""
        {"files":[{"path":"src/broken.test.mjs","state":"failed","duration_ms":0,"tests":[]},{"path":"src/math.test.mjs","state":"failed","duration_ms":5.03,"tests":[{"name":"math > adds","state":"passed","duration_ms":0.78},{"name":"math > compares objects","state":"failed","duration_ms":3.44}]}],"failures":[{"kind":"module","file":"src/broken.test.mjs","message":"cannot import this module","location":"src/broken.test.mjs:2"},{"kind":"test","file":"src/math.test.mjs","test":"math > compares objects","message":"AssertionError: expected 2 to be 3","diff":"- Expected\n+ Received","location":"src/math.test.mjs:4"},{"kind":"unhandled","message":"stray rejection","location":"src/strings.test.mjs:3"}]}
        """#
        let decoded = try Fyolod.testRunsDecoder().decode(Fyolod.TestRunDetail.self, from: Data(detail.utf8))
        XCTAssertEqual(decoded.files.map(\.path), ["src/broken.test.mjs", "src/math.test.mjs"])
        XCTAssertEqual(decoded.files[1].tests.map(\.state), ["passed", "failed"])
        XCTAssertEqual(decoded.failures.map(\.kind), ["module", "test", "unhandled"])
        XCTAssertEqual(decoded.failures[1].test, "math > compares objects")
        XCTAssertEqual(decoded.failures[1].diff, "- Expected\n+ Received")
        XCTAssertNil(decoded.failures[2].file)
    }
}
