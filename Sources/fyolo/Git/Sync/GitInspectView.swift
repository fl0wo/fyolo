import AppKit
import SwiftUI

/// The git pane's Inspect tab: everything in flight between this checkout and its
/// upstream, in the order it would move — **Uncommitted**, **Outgoing** (what a push
/// would send), **Incoming** (what a pull would bring). Each lists its commits and a
/// tree of the files they touch; clicking a file opens its before/after in the diff
/// overlay, a new file reading as its whole content.
///
/// Read-only, with no button that acts on the repository: the commit, push, or pull
/// itself is typed in the terminal. What this adds over Changes and Compare is the
/// upstream's side, and where the two collide — a file changed both upstream and
/// here is marked in every section it appears in.
///
/// Greyscale except for what a change *is*: green for added, red for removed.
struct GitInspectView: View {
    @EnvironmentObject var store: FyoloStore
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var model: GitSyncModel
    /// The git pane's own working-tree read — reused rather than read a second time.
    @ObservedObject var panel: GitPanelModel
    /// The git pane's root, which the uncommitted rows' diffs are read against, as
    /// the Changes tab reads them.
    let paneRoot: String

    @State private var collapsedSections: Set<GitInspectSection> = []
    @State private var collapsedFolders: Set<String> = []
    @State private var hovered: String?

    private var syncRoot: String { model.status?.repositoryRoot ?? paneRoot }

    /// Paths an incoming change shares with a local one, committed or not.
    private var overlap: Set<String> {
        GitInspect.overlap(
            incoming: model.incoming?.files ?? [],
            local: (model.outgoing?.files ?? []) + panel.changes)
    }

    var body: some View {
        let overlap = overlap
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(GitInspectSection.allCases, id: \.self) { section in
                        Section {
                            if !collapsedSections.contains(section) {
                                content(section, overlap: overlap)
                            }
                        } header: {
                            header(section)
                        }
                        .id(section)
                    }
                }
                .padding(.bottom, 10)
            }
            .onAppear {
                model.setInspecting(store.inspectorVisible)
                if let section = model.consumePendingInspect() { reveal(section, proxy: proxy) }
            }
            .onReceive(model.inspectRequests) { _ in
                if let section = model.consumePendingInspect() { reveal(section, proxy: proxy) }
            }
        }
        .onDisappear { model.setInspecting(false) }
        .onChange(of: store.inspectorVisible) { _, visible in model.setInspecting(visible) }
    }

    private func reveal(_ section: GitInspectSection, proxy: ScrollViewProxy) {
        collapsedSections.remove(section)
        // After the expansion lays out, or the scroll lands on the old height.
        DispatchQueue.main.async {
            withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(section, anchor: .top) }
        }
    }

    // MARK: Headers

    private func header(_ section: GitInspectSection) -> some View {
        let files = files(in: section)
        let hasContent = !files.isEmpty || !(range(of: section)?.commits.isEmpty ?? true)
        let collapsed = collapsedSections.contains(section)
        return Button {
            if collapsed { collapsedSections.remove(section) } else { collapsedSections.insert(section) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .foregroundStyle(.secondary)
                    .opacity(hasContent ? 1 : 0.35)
                Text(title(section))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(hasContent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Text(detail(section))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                totals(files)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(Color(nsColor: settings.terminalBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    private func title(_ section: GitInspectSection) -> String {
        switch section {
        case .uncommitted: return localized("Uncommitted")
        case .outgoing: return localized("Outgoing")
        case .incoming: return localized("Incoming")
        }
    }

    private func detail(_ section: GitInspectSection) -> String {
        switch section {
        case .uncommitted:
            let count = panel.changes.count
            return count == 1 ? localized("1 file") : localized("\(count) files")
        case .outgoing, .incoming:
            guard let range = range(of: section) else { return "" }
            let count = range.commits.count
            let commits = count == 1 ? localized("1 commit") : localized("\(count) commits")
            return section == .outgoing
                ? localized("\(commits) to \(range.base)")
                : localized("\(commits) from \(range.base)")
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ section: GitInspectSection, overlap: Set<String>) -> some View {
        switch section {
        case .uncommitted:
            if panel.isLoading {
                loadingLine
            } else if panel.changes.isEmpty {
                note(localized("The working tree is clean."))
            } else {
                fileTree(panel.changes, section: section, overlap: overlap)
            }
        case .outgoing, .incoming:
            if section == .incoming { fetchLine }
            if let range = range(of: section) {
                if section == .incoming, !overlap.isEmpty { overlapLine(overlap.count) }
                if range.files.isEmpty, range.commits.isEmpty {
                    note(section == .outgoing ? localized("Nothing to push.") : localized("Nothing to pull."))
                } else {
                    if !range.commits.isEmpty { commitList(range.commits) }
                    if !range.files.isEmpty { fileTree(range.files, section: section, overlap: overlap) }
                }
            } else if model.isLoadingRanges || model.status == nil {
                loadingLine
            } else {
                note(missingRangeNote(section))
            }
        }
    }

    private func missingRangeNote(_ section: GitInspectSection) -> String {
        guard let status = model.status else { return "" }
        if status.branch == nil { return localized("HEAD is detached, so there is nothing to sync.") }
        if section == .incoming, status.upstream == nil {
            return localized("This branch has no upstream yet.")
        }
        return localized("This repository has no remote.")
    }

    /// What "nothing to pull" is only as good as.
    @ViewBuilder
    private var fetchLine: some View {
        if model.isFetching {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(localized("Checking for new commits…"))
            }
            .modifier(NoteStyle())
        } else if let fetched = model.lastFetched {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text(localized("Checked \(fetched.formatted(.relative(presentation: .named)))"))
            }
            .modifier(NoteStyle())
        } else if model.status?.upstream != nil {
            note(localized("Not checked against the remote yet."))
        }
    }

    private func overlapLine(_ count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(Palette.red)
            Text(count == 1
                 ? localized("1 file also changed here. Pulling may conflict.")
                 : localized("\(count) files also changed here. Pulling may conflict."))
        }
        .modifier(NoteStyle())
    }

    private var loadingLine: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
    }

    private func note(_ text: String) -> some View {
        Text(text).modifier(NoteStyle())
    }

    private struct NoteStyle: ViewModifier {
        func body(content: Content) -> some View {
            content
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func subheader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func commitList(_ commits: [GitCommit]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            subheader(localized("Commits"))
            ForEach(commits) { commit in
                VStack(alignment: .leading, spacing: 1) {
                    Text(commit.subject)
                        .font(settings.interfaceFont)
                        .lineLimit(1)
                    Text("\(commit.shortSHA) · \(commit.author) · \(commit.relativeDate)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(commit.subject)
            }
        }
    }

    // MARK: Files

    private func fileTree(_ changes: [GitChange], section: GitInspectSection, overlap: Set<String>) -> some View {
        let tree = GitReviewTree.build(changes)
        let collapsed = Set(collapsedFolders.compactMap { key in
            key.hasPrefix(folderKeyPrefix(section)) ? String(key.dropFirst(folderKeyPrefix(section).count)) : nil
        })
        // The overlay's ← / → walk follows the tree's order, not git's.
        let ordered = GitReviewTree.visibleRows(tree, collapsed: []).compactMap(\.node.change)
        return VStack(alignment: .leading, spacing: 0) {
            if section != .uncommitted { subheader(localized("Files")) }
            ForEach(GitReviewTree.visibleRows(tree, collapsed: collapsed), id: \.node.id) { row in
                fileRow(row.node, depth: row.depth, section: section,
                        isCollapsed: collapsed.contains(row.node.id),
                        overlaps: row.node.change.map { overlap.contains($0.path) } ?? false,
                        ordered: ordered)
            }
        }
    }

    private func folderKeyPrefix(_ section: GitInspectSection) -> String {
        "\(section)\u{1f}"
    }

    private func fileRow(
        _ node: GitReviewNode, depth: Int, section: GitInspectSection,
        isCollapsed: Bool, overlaps: Bool, ordered: [GitChange]
    ) -> some View {
        let rowID = folderKeyPrefix(section) + node.id
        let range = section == .uncommitted ? nil : self.range(of: section)?.range
        let shown = store.openDiff
        let isSelected = !node.isFolder && shown?.change.path == node.id && shown?.range == range
            && shown?.repoRoot == (section == .uncommitted ? paneRoot : syncRoot)
        return HStack(spacing: 6) {
            if node.isFolder {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 10)
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(node.name)
                    .font(settings.interfaceFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
            } else if let change = node.change {
                FileIconView(url: fileURL(change.path, section: section), size: 14, symbolSize: 12,
                             ink: .secondary)
                    .frame(width: 16)
                Text(node.name)
                    .font(settings.interfaceFont)
                    .strikethrough(change.status == .deleted)
                    .foregroundStyle(change.status == .deleted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if overlaps {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.red)
                        .help(section == .incoming
                              ? localized("Also changed here. Pulling may conflict.")
                              : localized("Also changed upstream. Pulling may conflict."))
                }
                Spacer(minLength: 4)
                counts(change)
                Text(change.status.letter)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint(change.status))
                    .frame(width: 12)
            }
        }
        .padding(.leading, 14 + CGFloat(depth) * 14)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        // `chrome: nil` keeps the highlight grey whatever the theme's accent is.
        .background(SidebarRowHighlight(isSelected: isSelected, isHovering: hovered == rowID, chrome: nil))
        .onHover { hovered = $0 ? rowID : (hovered == rowID ? nil : hovered) }
        .onTapGesture {
            if node.isFolder {
                if collapsedFolders.contains(rowID) { collapsedFolders.remove(rowID) } else { collapsedFolders.insert(rowID) }
            } else if let change = node.change {
                open(change, section: section, range: range, siblings: ordered)
            }
        }
        .help(node.change.map { change in
            change.originalPath.map { "\($0) → \(change.path)" } ?? change.path
        } ?? node.id)
    }

    /// Only what a change *is* gets a colour: added green, removed red. Edits, renames,
    /// and conflicts read in grey, and the letter says which.
    private func tint(_ status: GitFileStatus) -> Color {
        switch status {
        case .added, .untracked: return Palette.green
        case .deleted: return Palette.red
        case .modified, .renamed, .copied, .conflicted: return .secondary
        }
    }

    private func counts(_ change: GitChange) -> some View {
        HStack(spacing: 4) {
            if change.isBinary {
                Text(localized("binary")).foregroundStyle(.secondary)
            } else {
                if change.additions > 0 { Text("+\(change.additions)").foregroundStyle(Palette.green) }
                if change.deletions > 0 { Text("−\(change.deletions)").foregroundStyle(Palette.red) }
            }
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .opacity(0.85)
        .fixedSize()
    }

    @ViewBuilder
    private func totals(_ files: [GitChange]) -> some View {
        let additions = files.reduce(0) { $0 + $1.additions }
        let deletions = files.reduce(0) { $0 + $1.deletions }
        HStack(spacing: 5) {
            if additions > 0 { Text("+\(additions)").foregroundStyle(Palette.green) }
            if deletions > 0 { Text("−\(deletions)").foregroundStyle(Palette.red) }
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .opacity(0.85)
    }

    // MARK: Helpers

    private func range(of section: GitInspectSection) -> GitSyncRange? {
        switch section {
        case .uncommitted: return nil
        case .outgoing: return model.outgoing
        case .incoming: return model.incoming
        }
    }

    private func files(in section: GitInspectSection) -> [GitChange] {
        section == .uncommitted ? panel.changes : range(of: section)?.files ?? []
    }

    private func open(_ change: GitChange, section: GitInspectSection, range: String?, siblings: [GitChange]) {
        // An image or PDF reads better as itself than as a binary diff — but only the
        // working tree holds the version an uncommitted row is about.
        let url = fileURL(change.path, section: section)
        if section == .uncommitted, FileActivation.previewsRatherThanDiff(url),
           FileManager.default.fileExists(atPath: url.path) {
            store.openFileInEditor(url)
            return
        }
        store.openDiff = GitDiffRequest(
            repoRoot: section == .uncommitted ? paneRoot : syncRoot,
            change: change, range: range, siblings: siblings)
    }

    private func fileURL(_ path: String, section: GitInspectSection) -> URL {
        URL(fileURLWithPath: section == .uncommitted ? paneRoot : syncRoot).appendingPathComponent(path)
    }
}
