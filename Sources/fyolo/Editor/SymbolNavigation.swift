import AppKit
import SwiftUI
import FyoloShared

/// Where one open file's ⌘-click lookups go: the daemon that holds the file —
/// this Mac's over its socket, a device's over its pipe — and the file's path
/// under that daemon's root. The daemon reads the code (`fs.references`), so a
/// local checkout and one across the network give the same answer.
struct SymbolLookup {
    let provider: DeviceFileProvider
    /// What a hit's relative path resolves against: real on this Mac, synthetic
    /// (names and icons only) for a device, exactly as the Search pane's.
    let base: URL
    /// The open file, relative to the provider's root.
    let relativePath: String
    /// Whether hits name files on this Mac, so their rows can be dragged out.
    let isLocal: Bool
    /// Opens a root-relative path at a 1-based line. `returnLine` is the line the
    /// editor is leaving, which the host records so Back can come back to it.
    let open: (_ relativePath: String, _ line: Int, _ returnLine: Int) -> Void
}

/// What a ⌘-click does with what the daemon answered: go straight to the one
/// place that matters, or list them.
enum ReferenceNavigation {
    struct Location: Equatable {
        let path: String
        let line: Int
    }

    enum Decision: Equatable {
        case jump(Location)
        case list
    }

    /// WebStorm's rule, sharpened by what the user meant by each click:
    /// - on a use of a name, its one definition is the answer;
    /// - on the definition, the answer is where it is used — when that is a
    ///   single other file, go there; when it is this file, or several, or
    ///   nowhere, list it, because jumping would hide the answer;
    /// - on a module path, the module;
    /// - a name the daemon could not resolve, or a package's symbol with no
    ///   definition in the tree, always lists: a guess is not a destination.
    static func decide(_ result: Fyolod.ReferencesResult, clickedPath: String) -> Decision {
        let symbol = result.symbol
        switch symbol.kind {
        case "module":
            guard let module = symbol.definitions.first else { return .list }
            return .jump(Location(path: module.path, line: max(module.line, 1)))
        case "export", "local":
            break
        default:
            return .list
        }
        guard symbol.atDefinition else {
            guard symbol.definitions.count == 1, let definition = symbol.definitions.first
            else { return .list }
            return .jump(Location(path: definition.path, line: definition.line))
        }
        let usages = result.hits.filter { $0.kind == SymbolHitKind.usage }
        let files = Set(usages.map(\.path))
        guard files.count == 1, let file = files.first, file != clickedPath,
              let first = usages.first else { return .list }
        return .jump(Location(path: first.path, line: first.line))
    }
}

/// The `kind` strings a reference hit carries (`symbols::kind` in fyolod).
enum SymbolHitKind {
    static let definition = "definition"
    static let usage = "usage"
    static let `import` = "import"
    static let reexport = "reexport"
    static let match = "match"
    static let unrelated = "unrelated"
}

/// What the usages popover is showing.
@MainActor
final class UsagesModel: ObservableObject {
    enum State {
        case loading(name: String)
        case loaded(Fyolod.ReferencesResult)
        case failed(String)
    }

    @Published var state: State

    init(name: String) {
        state = .loading(name: name)
    }
}

/// The list a ⌘-click shows when there is no single place to go: the
/// definition, then usages grouped under their file, then imports and
/// re-exports, then — folded away, but there to check — everything with the
/// same text that is provably something else. The rows are the Search pane's
/// own (`FileHeaderRow`, `ExcerptView`), so a usage reads exactly like a hit.
struct UsagesPopover: View {
    @ObservedObject var model: UsagesModel
    let lookup: SymbolLookup
    @ObservedObject var settings: AppSettings
    let onOpen: (_ relativePath: String, _ line: Int) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var collapsed: Set<String> = []
    @State private var showsUnrelated = false

    static let size = NSSize(width: 560, height: 420)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.state {
            case .loading(let name):
                header(name: name, caption: localized("Finding usages…"), note: nil)
                Spacer(minLength: 0)
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            case .failed(let message):
                header(name: localized("Can’t Find Usages"), caption: message, note: nil)
                Spacer(minLength: 0)
            case .loaded(let result):
                header(name: result.symbol.name, caption: caption(result), note: result.symbol.note)
                Divider()
                list(result)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    }

    private func header(name: String, caption: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                if let note {
                    Text(note)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary.opacity(0.6)))
                }
            }
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func caption(_ result: Fyolod.ReferencesResult) -> String {
        let usages = result.hits.filter { $0.kind == SymbolHitKind.usage }
        let files = Set(usages.map(\.path)).count
        let more = result.limitHit ? "+" : ""
        switch result.symbol.kind {
        case "name":
            return localized("Not resolved. Every whole-word match in files of this kind.")
        case "module":
            return localized("Module")
        default:
            if usages.isEmpty { return localized("No usages") }
            let count = usages.reduce(0) { $0 + max($1.spans.count, 1) }
            return localized("\(count)\(more) usages in \(files) files")
        }
    }

    private struct Section: Identifiable {
        let id: String
        let title: String
        let hits: [Fyolod.SearchHit]
    }

    private func sections(_ result: Fyolod.ReferencesResult) -> [Section] {
        let hits = result.hits
        func of(_ kinds: String...) -> [Fyolod.SearchHit] {
            hits.filter { kinds.contains($0.kind ?? "") }
        }
        return [
            Section(id: "definition", title: localized("Definition"),
                    hits: result.symbol.definitions + of(SymbolHitKind.definition)),
            Section(id: "usage", title: localized("Usages"), hits: of(SymbolHitKind.usage)),
            Section(id: "match", title: localized("Matches"), hits: of(SymbolHitKind.match)),
            Section(id: "import", title: localized("Imports"), hits: of(SymbolHitKind.import)),
            Section(id: "reexport", title: localized("Re-exports"), hits: of(SymbolHitKind.reexport)),
        ].filter { !$0.hits.isEmpty }
    }

    private func list(_ result: Fyolod.ReferencesResult) -> some View {
        let unrelated = result.hits.filter { $0.kind == SymbolHitKind.unrelated }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sections(result)) { section in
                    sectionTitle(section.title, count: section.hits.count)
                    files(section.hits, section: section.id)
                }
                if !unrelated.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) { showsUnrelated.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .rotationEffect(.degrees(showsUnrelated ? 90 : 0))
                            Text(localized("\(unrelated.count) unrelated matches"))
                                .font(.system(size: 11, weight: .medium))
                            Text(localized("Same text, different symbol"))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showsUnrelated {
                        files(unrelated, section: "unrelated")
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        Text("\(title.uppercased())  \(count)")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    /// Hits under their file, in the order the daemon ranked them.
    @ViewBuilder
    private func files(_ hits: [Fyolod.SearchHit], section: String) -> some View {
        let matches = hits.map { ContentMatch($0, base: lookup.base) }
        let groups = Dictionary(grouping: matches, by: \.relative)
        let order = matches.map(\.relative).reduce(into: [String]()) { order, path in
            if !order.contains(path) { order.append(path) }
        }
        let chrome = settings.chromeTheme(for: colorScheme)
        ForEach(order, id: \.self) { relative in
            let items = (groups[relative] ?? []).sorted { $0.line < $1.line }
            let key = section + "\u{1f}" + relative
            let isExpanded = !collapsed.contains(key)
            if let first = items.first {
                FileHeaderRow(
                    url: first.url, relative: relative,
                    count: items.reduce(0) { $0 + max($1.spans.count, 1) },
                    isExpanded: isExpanded, chrome: chrome,
                    toggleExpanded: {
                        if isExpanded { collapsed.insert(key) } else { collapsed.remove(key) }
                    },
                    allowsDrag: lookup.isLocal,
                    open: { onOpen(relative, first.line) })
                if isExpanded {
                    let excerpts = SearchExcerpt.compose(items)
                    ForEach(Array(excerpts.enumerated()), id: \.element.id) { index, excerpt in
                        if index > 0 { ExcerptGap() }
                        ExcerptView(
                            excerpt: excerpt, url: first.url, settings: settings,
                            colorScheme: colorScheme, chrome: chrome,
                            open: { line in onOpen(relative, line) })
                    }
                }
            }
        }
    }
}

/// Holds the one usages popover an editor may have open, anchored at the word
/// that was clicked.
@MainActor
final class UsagesPopoverPresenter: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?

    var isShown: Bool { popover?.isShown == true }

    func show(_ content: UsagesPopover, at rect: NSRect, in view: NSView) {
        close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = UsagesPopover.size
        popover.contentViewController = NSHostingController(rootView: content)
        popover.delegate = self
        self.popover = popover
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    func close() {
        popover?.close()
        popover = nil
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated { popover = nil }
    }
}

/// What a ⌘-click hands the editor: where in the text, and where on screen.
struct SymbolClick {
    /// UTF-16 offset of the click in the text view's string.
    let location: Int
    /// The clicked word's rect, in `view`'s coordinates — the popover's anchor.
    let rect: NSRect
    let view: NSView
    /// Find Usages from the context menu: always the list, never a jump.
    let listsAlways: Bool
}
