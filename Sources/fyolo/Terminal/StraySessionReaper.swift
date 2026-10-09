import Darwin
import Foundation

/// Sessions whose owning process died without cleaning up after itself.
///
/// Nothing else notices them. A tombstone records that a session *ended*; it
/// does not reach the process, and the daemon that would have killed the group
/// is the thing that died. So this runs at launch and sweeps.
enum StraySessionReaper {
    /// Kills session processes whose owner died without running any
    /// teardown. Those children re-parent to launchd and — because agent
    /// TUIs swallow the SIGHUP the closing PTY delivers — idle forever,
    /// accumulating into a memory-pressure swarm.
    ///
    /// The owner used to be this app. It is now `fyolod`, which changes
    /// which crash this defends against but not the shape of the leak or
    /// the way to find it: a session still carries the env this app stamps
    /// into it (`FYOLO_SESSION` plus `TERM_PROGRAM=fyolo` — the session id
    /// alone leaks into unrelated processes when an editor is launched from
    /// a pane, but such descendants overwrite TERM_PROGRAM), and an orphan
    /// still shows `ppid == 1`. A live daemon's sessions have that daemon as
    /// their parent, so two daemons never reap each other's running work.
    static func reapStrayOrphans() {
        DispatchQueue.global(qos: .utility).async {
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            // -E appends each process's environment to the command column
            // (own-user processes only, which is exactly the scope wanted);
            // `tty` gates out daemons — see the guard below.
            ps.arguments = ["-axEww", "-o", "pid=,ppid=,tty=,command="]
            let out = Pipe()
            ps.standardOutput = out
            do { try ps.run() } catch {
                Log.pty.error("reap: ps failed to launch: \(error.localizedDescription, privacy: .public)")
                return
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            ps.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") {
                guard line.contains("FYOLO_SESSION="),
                      line.contains("TERM_PROGRAM=fyolo") else { continue }
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                // fields: pid, ppid, tty, command… — `ppid == 1` alone can't
                // tell a stranded agent from a tool that daemonized off the
                // pane (a tmux/screen server, or fyolo itself): both
                // re-parent to launchd carrying the stamps. The tell is the
                // tty — a stray still holds its dead PTY (`ttysNNN`), which is
                // why it leaks; a daemon shed it (`??`).
                guard fields.count >= 3,
                      let pid = pid_t(fields[0]), let ppid = pid_t(fields[1]),
                      ppid == 1, pid != getpid(),
                      fields[2] != "??"
                else { continue }
                Log.pty.info("reaping stray session process pid=\(pid, privacy: .public)")
                // The group first (the leader's tree), then the pid itself —
                // an orphaned *grandchild* isn't a group leader, so killpg
                // alone would miss it.
                killpg(pid, SIGKILL)
                kill(pid, SIGKILL)
            }
        }
    }
}
