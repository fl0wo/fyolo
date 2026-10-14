import Foundation

// MARK: - Plugin contract

/// Something a plugin asks fyolo to do. Plugins describe actions as data and
/// the app performs them, so a plugin never reaches into the store, a terminal
/// or the file system on its own: what it can do is exactly this list. That is
/// what keeps a plugin testable without a window, and what lets a plugin later
/// arrive as a manifest instead of compiled code — it would produce the same
/// values.
enum PluginCommand: Hashable, Sendable {
    /// Run `task` in a fyolo terminal, and remember it in the run capsule's recents.
    case run(RunTask)
}

/// Something a plugin knows how to run: a script, a make target, a whole file.
/// The run capsule, its recents and the stop button work on this value alone, so
/// a new kind of runnable is a new plugin, never a change to how runs are run.
struct RunTask: Hashable, Codable, Sendable, Identifiable {
    /// What the capsule shows: `e2e`, `build`, `deploy.sh`.
    let name: String
    /// The shell line typed into the terminal.
    let command: String
    let directory: URL

    /// Two runs of the same line in the same folder are one task — the recents
    /// never hold it twice.
    var id: String { directory.standardizedFileURL.path + "\u{0}" + command }

    /// A word as one shell argument: bare when it is made of the characters names
    /// and paths use (`build:prod`, `scripts/x.sh`), single-quoted otherwise.
    static func shellWord(_ word: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ":._/-@+="))
        if !word.isEmpty, word.unicodeScalars.allSatisfy({ plain.contains($0) }) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// A clickable marker in the editor's gutter, beside one line of the open file.
struct GutterAction: Hashable, Sendable {
    /// 1-based, as the gutter numbers lines.
    let line: Int
    /// The tooltip — what clicking will do.
    let help: String
    let command: PluginCommand

    /// The task behind the marker, so the gutter can show it running.
    var task: RunTask? {
        switch command {
        case .run(let task): task
        }
    }
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
    /// The task that runs `file` as a whole (a shell script), offered on the file
    /// tree's right-click menu. `nil` for a file that isn't run that way.
    func wholeFileTask(for file: URL) -> RunTask?
}

extension FyoloPlugin {
    func gutterActions(for file: URL, text: String) -> [GutterAction] { [] }
    func wholeFileTask(for file: URL) -> RunTask? { nil }
}

// MARK: - Registry

/// Every plugin fyolo ships, and the questions the app asks across all of them.
@MainActor
enum PluginRegistry {
    static let all: [any FyoloPlugin] = [
        PackageScriptsPlugin(),
        MakefilePlugin(),
        ScriptFilePlugin(),
        LinearPlugin(),
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

    /// How the first enabled plugin that runs `file` whole would run it.
    static func wholeFileTask(for file: URL, settings: AppSettings) -> RunTask? {
        enabled(in: settings).lazy.compactMap { $0.wholeFileTask(for: file) }.first
    }
}
