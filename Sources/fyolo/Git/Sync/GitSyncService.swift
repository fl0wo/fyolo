import Foundation

/// The reads behind the branch name's badge and the git pane's Inspect tab. Reads only — the
/// one network call is `fetch`, which moves remote-tracking refs and never the
/// branch, the index, or the working tree.
extension GitService {
    /// The repository's top level for any folder inside it, or `nil` outside a work tree.
    static func topLevel(of folder: String) async -> String? {
        await offMain {
            run(["rev-parse", "--show-toplevel"], in: folder)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The capsule's whole state in one `git status`; a second process (`git remote`)
    /// only for a branch with no upstream, to learn where it would be published.
    static func syncStatus(in root: String) async -> GitSyncStatus? {
        await offMain {
            guard let porcelain = run(["status", "--porcelain=v2", "--branch"], in: root) else { return nil }
            var status = GitSyncStatus(porcelain: porcelain, repositoryRoot: root)
            if status.branch != nil, status.upstream == nil {
                let remotes = (run(["remote"], in: root) ?? "")
                    .split(separator: "\n").map(String.init)
                status.publishRemote = GitSyncStatus.publishRemote(from: remotes)
            }
            return status
        }
    }

    /// `git fetch` for the branch's remote, so "behind" means something. Non-interactive
    /// by construction: no terminal to prompt on, `GIT_TERMINAL_PROMPT=0` for HTTPS,
    /// and a deadline after which the fetch is terminated — a remote that wants a
    /// password simply stays unfetched. System git and system ssh, so `~/.ssh/config`
    /// decides how the remote is reached.
    static func fetch(in root: String, timeout: TimeInterval = 60) async -> Bool {
        await offMain {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root, "fetch", "--quiet"]
            var environment = GitEnvironment.optionalLocksDisabled
            environment["GIT_TERMINAL_PROMPT"] = "0"
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                Log.app.error("git fetch could not start: \(error.localizedDescription, privacy: .public)")
                return false
            }
            let deadline = DispatchTime.now() + timeout
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
                if process.isRunning { process.terminate() }
            }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
    }

    /// `git pull --ff-only`: brings the branch up to its upstream when that is a
    /// fast-forward, and refuses otherwise — a diverged branch or an uncommitted
    /// file in the way is the user's to settle in the terminal, never a merge
    /// commit made on their behalf. Non-interactive like `fetch`. Returns git's
    /// own words on failure, `nil` on success.
    static func pull(in root: String, timeout: TimeInterval = 120) async -> String? {
        await offMain {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root, "pull", "--ff-only", "--quiet"]
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_TERMINAL_PROMPT"] = "0"
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            do {
                try process.run()
            } catch {
                return error.localizedDescription
            }
            let deadline = DispatchTime.now() + timeout
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
                if process.isRunning { process.terminate() }
            }
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus != 0 else { return nil }
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return message.isEmpty ? localized("git pull did not complete.") : message
        }
    }

    /// The files and commits a push (`.outgoing`) or pull (`.incoming`) would carry.
    /// Outgoing measures `HEAD` against `base`, incoming `base` against `HEAD`; both
    /// from the merge base, so a diverged branch shows each side's own changes rather
    /// than the other's inverted. A branch with no upstream is measured against the
    /// trunk it would be opened against, so publishing it still shows what it adds.
    static func syncRange(_ section: GitInspectSection, against base: String, in root: String) async -> GitSyncRange {
        await offMain {
            let (from, to) = section == .incoming ? ("HEAD", base) : (base, "HEAD")
            let range = "\(from)...\(to)"
            let files = rangeChanges(
                numstat: run(["diff", "--numstat", "-z", "-M", range], in: root) ?? "",
                nameStatus: run(["diff", "--name-status", "-z", "-M", range], in: root) ?? "")
            return GitSyncRange(base: base, range: range, files: files,
                                commits: loadLog(root, 200, range: "\(from)..\(to)"))
        }
    }
}
