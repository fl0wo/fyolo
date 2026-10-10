import Foundation

// MARK: - Plugin contract

/// Something a plugin asks fyolo to do. Plugins describe actions as data and
/// the app performs them, so a plugin never reaches into the store, a terminal
/// or the file system on its own: what it can do is exactly this list. That is
/// what keeps a plugin testable without a window, and what lets a plugin later
/// arrive as a manifest instead of compiled code — it would produce the same
/// values.
enum PluginCommand: Hashable, Sendable {
    /// Open a terminal in `directory` beside the session in view, named `title`,
    /// and run `command` in it.
    case runInTerminal(command: String, directory: URL, title: String)
}

/// A clickable marker in the editor's gutter, beside one line of the open file.
struct GutterAction: Hashable, Sendable {
    /// 1-based, as the gutter numbers lines.
    let line: Int
    /// The tooltip — what clicking will do.
    let help: String
    let command: PluginCommand
}

/// A fyolo plugin: a named feature the user can switch off in Settings ▸
/// Plugins. Today plugins are built in; the protocol is the seam a third-party
/// one would plug into.
@MainActor
protocol FyoloPlugin {
    /// Stable identity, persisted in settings — never change it once shipped.
    var id: String { get }
    var name: String { get }
    /// One sentence for the Settings row: what the plugin adds.
    var summary: String { get }
    /// The gutter markers this plugin puts on `file`, whose current contents are
    /// `text` (the live buffer, unsaved edits included). Empty for a file the
    /// plugin has nothing to say about — the common case, so return early.
    func gutterActions(for file: URL, text: String) -> [GutterAction]
}

// MARK: - Registry

/// Every plugin fyolo ships, and the questions the app asks across all of them.
@MainActor
enum PluginRegistry {
    static let all: [any FyoloPlugin] = [
        PackageScriptsPlugin(),
    ]

    static func enabled(in settings: AppSettings) -> [any FyoloPlugin] {
        all.filter { settings.isPluginEnabled($0.id) }
    }

    /// The gutter markers for `file` from every enabled plugin, one per line —
    /// the first plugin to claim a line keeps it.
    static func gutterActions(for file: URL, text: String, settings: AppSettings) -> [GutterAction] {
        var seenLines = Set<Int>()
        return enabled(in: settings)
            .flatMap { $0.gutterActions(for: file, text: text) }
            .filter { seenLines.insert($0.line).inserted }
    }
}
