import FyoloShared
import XCTest

/// What the roster shows when `ssh <host> fyolod stdio` dies before the
/// handshake (issue #498): the diagnosis is ssh's own last word, never the
/// narration around it, and a missing daemon is translated into the fix.
final class FyolodRemoteDiagnosisTests: XCTestCase {
    func testPermissionDeniedIsTheVerdict() {
        // BatchMode=yes against password-only auth: the shape behind "my ssh
        // works but Fyolo can't connect" — interactive ssh prompts, ours may not.
        XCTAssertEqual(
            Fyolod.remoteFailureDiagnosis(
                stderr: "yqn-14: Permission denied (publickey,password).\n"),
            "yqn-14: Permission denied (publickey,password).")
    }

    func testLastLineWinsOverEarlierNoise() {
        let stderr = """
        Warning: Permanently added 'yqn-14' (ED25519) to the list of known hosts.
        yqn-14: Permission denied (publickey,password).
        """
        XCTAssertEqual(
            Fyolod.remoteFailureDiagnosis(stderr: stderr),
            "yqn-14: Permission denied (publickey,password).")
    }

    func testMissingFyolodNamesTheFix() {
        for shell in [
            "bash: line 1: /home/user/.local/bin/fyolod: No such file or directory",
            "zsh:1: no such file or directory: /root/.local/bin/fyolod",
            "sh: 1: /home/user/.local/bin/fyolod: not found",
        ] {
            XCTAssertEqual(
                Fyolod.remoteFailureDiagnosis(stderr: shell),
                "fyolod isn't installed on this machine yet — a new terminal on it sets it up")
        }
    }

    func testDeniedDaemonPathIsNotCalledMissing() {
        // The daemon's own path failing for a reason other than absence — a
        // noexec mount, wrong permissions — must show that reason, not an
        // install hint for a binary that is right there.
        let stderr = "zsh: permission denied: /opt/bin/fyolod"
        XCTAssertEqual(Fyolod.remoteFailureDiagnosis(stderr: stderr), stderr)
    }

    func testAnotherMissingFileIsNotCalledAMissingDaemon() {
        // The daemon itself complaining about some other path must pass through
        // verbatim, not be rewritten into an install prompt.
        let stderr = "fyolod: /tmp/nowhere: No such file or directory"
        XCTAssertEqual(Fyolod.remoteFailureDiagnosis(stderr: stderr), stderr)
    }

    func testNarrationAloneIsNoDiagnosis() {
        // A tail of only warnings and the EOF's own echo explains nothing; the
        // caller keeps its generic error instead of showing noise as a reason.
        let stderr = """
        Warning: Permanently added 'yqn-14' (ED25519) to the list of known hosts.
        Connection to yqn-14 closed.
        """
        XCTAssertNil(Fyolod.remoteFailureDiagnosis(stderr: stderr))
    }

    func testEmptyStderrIsNoDiagnosis() {
        XCTAssertNil(Fyolod.remoteFailureDiagnosis(stderr: ""))
        XCTAssertNil(Fyolod.remoteFailureDiagnosis(stderr: "\n  \n"))
    }
}
