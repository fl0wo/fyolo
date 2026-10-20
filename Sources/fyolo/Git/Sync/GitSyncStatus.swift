import Foundation

/// Where a checkout stands against its upstream and how much is waiting to be
/// committed — everything the toolbar's git glyphs draw, read from a single
/// `git status --porcelain=v2 --branch` so they cost one process per refresh.
struct GitSyncStatus: Equatable, Sendable {
    /// The repository's top level. Every path Inspect lists is relative to it.
    var repositoryRoot: String
    /// The commit HEAD points at; `nil` in a repository with no commit yet. Part of
    /// what decides whether the Inspect tab's outgoing and incoming lists are stale.
    var head: String?
    /// The checked-out branch; `nil` on a detached HEAD, which has nothing to sync.
    var branch: String?
    /// The upstream ref (`origin/main`); `nil` when the branch tracks nothing.
    var upstream: String?
    var ahead = 0
    var behind = 0
    /// Changed paths in the index and working tree, untracked included. A hint for
    /// the toolbar, not Inspect's list: an untracked folder counts once here.
    var changedFiles = 0
    /// Of `changedFiles`, the new ones (added or untracked) and the removed ones; the
    /// rest are edits, renames, and conflicts.
    var addedFiles = 0
    var deletedFiles = 0
    /// Where a branch with no upstream would be published: `origin` when it exists,
    /// else the only remote. `nil` with an upstream, and with no remote at all.
    var publishRemote: String?

    var canCommit: Bool { changedFiles > 0 }

    enum Sync: Equatable, Sendable {
        case upToDate
        case pull(Int)
        case push(Int)
        case diverged(pull: Int, push: Int)
        /// The branch exists only here; pushing it creates the upstream.
        case publish(remote: String)
    }

    /// What the toolbar's cloud shows, or `nil` when there is nothing to
    /// sync against — a detached HEAD, or a repository with no remote.
    var sync: Sync? {
        guard branch != nil else { return nil }
        guard upstream != nil else { return publishRemote.map { .publish(remote: $0) } }
        switch (behind, ahead) {
        case (0, 0): return .upToDate
        case (let behind, 0): return .pull(behind)
        case (0, let ahead): return .push(ahead)
        case (let behind, let ahead): return .diverged(pull: behind, push: ahead)
        }
    }
}

extension GitSyncStatus {
    /// Reads porcelain v2 headers (`# branch.head`, `# branch.upstream`, `# branch.ab`)
    /// and counts its entry lines. Read without `-z`: a path git has to quote stays on
    /// its own line, and only the count of lines is needed.
    init(porcelain: String, repositoryRoot: String) {
        self.init(repositoryRoot: repositoryRoot)
        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: true) {
            if let oid = line.value(after: "# branch.oid ") {
                head = oid == "(initial)" ? nil : oid
            } else if let head = line.value(after: "# branch.head ") {
                branch = head == "(detached)" ? nil : head
            } else if let upstream = line.value(after: "# branch.upstream ") {
                self.upstream = upstream
            } else if let counts = line.value(after: "# branch.ab ") {
                for count in counts.split(separator: " ") {
                    if count.hasPrefix("+") { ahead = Int(count.dropFirst()) ?? 0 }
                    if count.hasPrefix("-") { behind = Int(count.dropFirst()) ?? 0 }
                }
            } else if line.count > 2, "12u?".contains(line[line.startIndex]),
                      line[line.index(after: line.startIndex)] == " " {
                changedFiles += 1
                // `XY`, the index and worktree status, follows an ordinary entry's type.
                let kind = line[line.startIndex]
                let codes = kind == "1" ? line.dropFirst(2).prefix(2) : ""
                if kind == "?" || codes.contains("A") {
                    addedFiles += 1
                } else if codes.contains("D") {
                    deletedFiles += 1
                }
            }
        }
    }

    /// `origin` when the repository has it, else the only remote, else none — the
    /// remote `git push -u` would be pointed at without asking.
    static func publishRemote(from remotes: [String]) -> String? {
        if remotes.contains("origin") { return "origin" }
        return remotes.count == 1 ? remotes.first : nil
    }
}

private extension Substring {
    func value(after prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

// MARK: - Inspect

/// The three things the git pane's Inspect tab lists, in the order they would move:
/// what is not committed yet, what a push would send, and what a pull would bring.
enum GitInspectSection: Hashable, Sendable, CaseIterable {
    case uncommitted, outgoing, incoming
}

/// The commits and files between `HEAD` and the ref it is measured against, read
/// from the merge base so a diverged branch shows each side's own work.
struct GitSyncRange: Equatable, Sendable {
    var base: String
    /// The `from...to` range the file diffs are read across.
    var range: String
    var files: [GitChange]
    var commits: [GitCommit]

    static func empty(base: String, range: String) -> GitSyncRange {
        GitSyncRange(base: base, range: range, files: [], commits: [])
    }
}

enum GitInspect {
    /// Paths an incoming change and a local one both touch — committed or not, and
    /// either side of a rename. A pull meets these first: a merge conflict when the
    /// local side is committed, and a refused pull when it is still uncommitted.
    static func overlap(incoming: [GitChange], local: [GitChange]) -> Set<String> {
        func paths(_ changes: [GitChange]) -> Set<String> {
            Set(changes.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) })
        }
        return paths(incoming).intersection(paths(local))
    }
}

/// One row of an Inspect section's file tree. Folders that hold a single folder are folded
/// into one row (`Sources/fyolo/Git`), the way compact folders read in an editor, so a
/// deep change does not cost a screen of chevrons.
struct GitReviewNode: Identifiable, Hashable, Sendable {
    /// The full repo-relative path — a file's path, or a folder's.
    let id: String
    /// What the row says: the file name, or the folded folder chain.
    let name: String
    /// The change, on a file row; `nil` on a folder.
    let change: GitChange?
    /// Every file path below a folder (a file's own path on a file row).
    let filePaths: [String]
    let children: [GitReviewNode]

    var isFolder: Bool { change == nil }
}

enum GitReviewTree {
    /// Builds the tree from flat changes: folders first, then files, each ordered by
    /// name the way the file tree orders them.
    static func build(_ changes: [GitChange]) -> [GitReviewNode] {
        final class Folder {
            var folders: [String: Folder] = [:]
            var files: [GitChange] = []
        }
        let root = Folder()
        for change in changes {
            var folder = root
            for component in change.path.split(separator: "/").dropLast().map(String.init) {
                if let existing = folder.folders[component] {
                    folder = existing
                } else {
                    let created = Folder()
                    folder.folders[component] = created
                    folder = created
                }
            }
            folder.files.append(change)
        }

        func nodes(in folder: Folder, prefix: String) -> [GitReviewNode] {
            let folders = folder.folders
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                .map { name, child -> GitReviewNode in
                    var name = name
                    var path = prefix + name
                    var child = child
                    // Fold a chain of single-folder folders into one row.
                    while child.files.isEmpty, child.folders.count == 1, let next = child.folders.first {
                        name += "/" + next.key
                        path += "/" + next.key
                        child = next.value
                    }
                    let children = nodes(in: child, prefix: path + "/")
                    return GitReviewNode(
                        id: path, name: name, change: nil,
                        filePaths: children.flatMap(\.filePaths), children: children)
                }
            let files = folder.files
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { GitReviewNode(id: $0.path, name: $0.name, change: $0, filePaths: [$0.path], children: []) }
            return folders + files
        }
        return nodes(in: root, prefix: "")
    }

    /// The rows on screen, in order, with their depth: every node whose folders are
    /// all open. Folders start open — an inspection hides nothing until asked to.
    static func visibleRows(_ nodes: [GitReviewNode], collapsed: Set<String>) -> [(node: GitReviewNode, depth: Int)] {
        var rows: [(node: GitReviewNode, depth: Int)] = []
        func walk(_ nodes: [GitReviewNode], depth: Int) {
            for node in nodes {
                rows.append((node, depth))
                if node.isFolder, !collapsed.contains(node.id) { walk(node.children, depth: depth + 1) }
            }
        }
        walk(nodes, depth: 0)
        return rows
    }
}
