import Foundation

/// The one walk-up-for-`.git` in the editor, backing the header's repo-relative path so a file's
/// shown path always agrees with the repo it belongs to.
enum GitRoot {
    /// The work-tree root containing `url`, or `nil` outside a repo. Matches any `.git` entry —
    /// a directory in a normal clone, a *file* in linked worktrees and submodules.
    static func find(for url: URL) -> URL? {
        var dir = url.standardizedFileURL.deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
