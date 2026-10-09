import Foundation
import GhosttyTheme
import FyoloShared

/// fyolo's terminal-theme library: the built-in schemes, plus whatever the user
/// has put in fyolo's `Themes` folder.
///
/// The built-ins are the curated list (`BuiltInThemes`), resolved live out of the
/// `GhosttyTheme` product rather than copied onto disk. Nothing to install,
/// nothing that goes stale when the pinned package updates a palette, and no way
/// for a selected name to resolve to nothing.
///
/// A user theme is a Ghostty-format file — the same `key = value` text Ghostty
/// itself reads from `~/.config/ghostty/themes` (`background = #hex`,
/// `palette = 0=#hex`, …) — so the thousands of community color schemes work
/// unchanged. This is the VSCode/Zed model: a theme the user made is a file on
/// their computer. A file wins over a built-in of the same name, so dropping in
/// your own `Nord` overrides ours instead of fighting it.
///
/// `theme(named:)` resolves past the curated list into the full bundled catalog,
/// because a Ghostty config's `theme = X` may name any of them and has to keep
/// painting. Such a name is listed too — see `selectableNames(dark:selection:)`.
///
/// Loading is lenient: a malformed file is skipped rather than failing the whole
/// load.
@MainActor
enum ThemeLibrary {
    /// Where user theme files live, alongside fyolo's other support data
    /// (`~/Library/Application Support/fyolo/Themes`).
    static var directory: URL {
        AppChannel.supportDirectory.appendingPathComponent("Themes", isDirectory: true)
    }

    // MARK: - Built-ins

    /// The curated list, filtered to the names the pinned catalog resolves so a
    /// package rename drops a stale entry instead of showing a dead one. The names
    /// are shared with the iPhone's picker (see `BuiltInThemes`), which offers the
    /// same set.
    static let builtInThemes: [GhosttyThemeDefinition] =
        BuiltInThemes.names.compactMap { GhosttyThemeCatalog.theme(named: $0) }

    /// Built-in names of one brightness, sorted — one slot's worth of the list.
    static func builtInNames(dark: Bool) -> [String] {
        (BundledThemes.all + builtInThemes)
            .filter { $0.isDark == dark }.map(\.name).sorted { $0.lowercased() < $1.lowercased() }
    }

    // MARK: - User themes

    /// Themes parsed from `directory`, cached after the first load. Call `reload()`
    /// to pick up files added or edited while the app is running.
    private static var cachedUserThemes: [GhosttyThemeDefinition]?

    static var userThemes: [GhosttyThemeDefinition] {
        if let cachedUserThemes { return cachedUserThemes }
        let loaded = loadUserThemes()
        cachedUserThemes = loaded
        return loaded
    }

    /// Re-reads the `Themes` folder and refreshes the cache, returning the fresh
    /// list. The pickers call this on appear (so newly dropped files show up) and
    /// from a "Reload" button (so an edit to an open theme takes effect live).
    @discardableResult
    static func reload() -> [GhosttyThemeDefinition] {
        let loaded = loadUserThemes()
        cachedUserThemes = loaded
        return loaded
    }

    /// Every user theme name, sorted — the Appearance tab's "N in your folder".
    static var userThemeNames: [String] {
        userThemes.map(\.name).sorted { $0.lowercased() < $1.lowercased() }
    }

    /// User theme names of one brightness, sorted — the picker's own section.
    static func userThemeNames(dark: Bool) -> [String] {
        userThemes.filter { $0.isDark == dark }.map(\.name).sorted { $0.lowercased() < $1.lowercased() }
    }

    // MARK: - Resolution

    /// Resolves a theme by name: the user's own file first, then the bundled
    /// catalog. Resolving past the built-ins into the full catalog is what lets a
    /// Ghostty config's `theme = Aardvark Blue` keep painting without fyolo
    /// copying a file to disk on its behalf.
    static func theme(named name: String) -> GhosttyThemeDefinition? {
        if let own = userThemes.first(where: { $0.name == name }) { return own }
        if let bundled = BundledThemes.all.first(where: { $0.name == name }) { return bundled }
        return GhosttyThemeCatalog.theme(named: name)
    }

    /// Resolves a name Ghostty wrote rather than one picked in fyolo, tolerating
    /// the spelling drift between Ghostty's theme list and the catalog's
    /// iTerm2-Color-Schemes names ("catppuccin-latte" vs "Catppuccin Latte",
    /// "Tokyo Night" vs "tokyonight"): exact match first, then one that ignores
    /// case and separators.
    ///
    /// User theme files are deliberately not consulted, which is the whole reason
    /// this is not `theme(named:)`. A Ghostty config can only mean Ghostty's own
    /// themes, so a same-named file in fyolo's folder must not quietly redirect
    /// it. Names the catalog cannot resolve are left to fyolo's own default —
    /// Ghostty also accepts theme files fyolo has no way to render.
    static func catalogTheme(matching name: String) -> GhosttyThemeDefinition? {
        if let exact = GhosttyThemeCatalog.theme(named: name) { return exact }
        let target = comparableName(name)
        return GhosttyThemeCatalog.allThemes.first { comparableName($0.name) == target }
    }

    /// A theme name reduced to what every spelling of it agrees on.
    private static func comparableName(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The names one slot may offer, filtered by each theme's own `isDark`
    /// (background luminance) so the Dark slot can never offer a theme that would
    /// render the wrong way.
    ///
    /// `selection` is appended when it resolves to something outside the list — a
    /// theme inherited from a Ghostty config. A name that is painting the window
    /// has to stay visible in the list that controls it, or it reads as a ghost.
    static func selectableNames(dark: Bool, selection: String = "") -> [String] {
        var names = userThemeNames(dark: dark)
        let owned = Set(names)
        names += builtInNames(dark: dark).filter { !owned.contains($0) }
        if !selection.isEmpty, !names.contains(selection),
           theme(named: selection)?.isDark == dark {
            names.append(selection)
        }
        return names
    }

    // MARK: - Files

    /// Writes a theme's definition into the `Themes` folder so the user has a file
    /// of their own to edit — this is how you fork a built-in. The first copy
    /// takes the theme's own name and so shadows it; a second becomes `Nord 2` and
    /// stands beside it rather than overwriting the edits in the first.
    ///
    /// Returns the file it wrote. The caller reveals it, because a duplicate the
    /// user cannot find is a duplicate that did nothing.
    @discardableResult
    static func duplicateToThemesFolder(named name: String) throws -> URL {
        guard let definition = theme(named: name) else { throw DuplicateRefusal.unknownTheme(name) }
        let url = try write(definition, as: uniqueName(basedOn: name))
        reload()
        return url
    }

    /// Why a duplicate did not happen.
    enum DuplicateRefusal: Error {
        /// The name resolves to neither a file nor the catalog — only reachable if
        /// the pinned package renamed a theme between listing it and the call.
        case unknownTheme(String)
    }

    /// `Nord`, then `Nord 2`, `Nord 3`, … — a duplicate never overwrites the file
    /// sitting next to it, so a second Duplicate is a second file rather than a
    /// silent loss of the first one's edits.
    private static func uniqueName(basedOn name: String) -> String {
        let taken = Set(userThemes.map(\.name))
        guard taken.contains(name) else { return name }
        var suffix = 2
        while taken.contains("\(name) \(suffix)") { suffix += 1 }
        return "\(name) \(suffix)"
    }

    /// One-time upgrade: earlier versions installed a theme by copying its file out
    /// of the catalog into the `Themes` folder. Those copies are redundant now —
    /// the same schemes resolve without a file — and a copy left behind would go on
    /// shadowing the built-in it duplicates, freezing that theme at the palette it
    /// had on the day it was installed.
    ///
    /// Only deletes files that still hold byte for byte what the old Install wrote.
    /// An edited file is the user's own theme and stays. Returns how many went.
    @discardableResult
    static func removeRedundantCatalogCopies() -> Int {
        var removed = 0
        for url in sortedFiles() {
            guard let contents = try? String(contentsOf: url, encoding: .utf8),
                  let definition = parse(
                    name: url.deletingPathExtension().lastPathComponent, contents: contents),
                  let catalogDefinition = GhosttyThemeCatalog.theme(named: definition.name),
                  contents == serialize(catalogDefinition)
            else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                removed += 1
            } catch {
                Log.app.error("could not remove redundant theme copy at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if removed > 0 { reload() }
        return removed
    }

    /// Creates the `Themes` folder if it does not exist yet and returns it, so
    /// "Open Themes Folder" always lands somewhere real even on a fresh install.
    /// Throws so a write can report why it could not happen.
    @discardableResult
    static func ensureDirectoryExists() throws -> URL {
        let url = directory
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Serializes a definition back to Ghostty `key = value` text and writes it to
    /// `directory` under `fileName`, with no extension — the folder already names a
    /// theme after its file's stem, so an extension would only be stripped back off
    /// on the next load. `parse` reads back an equal definition.
    @discardableResult
    static func write(_ definition: GhosttyThemeDefinition, as fileName: String? = nil) throws -> URL {
        try write(definition, into: ensureDirectoryExists(), as: fileName)
    }

    /// Writes into an explicit folder. `write(_:as:)` is this against the library's
    /// own folder; the parameter exists so the round-trip test can prove the file
    /// reads back equal without writing into the user's Themes folder.
    @discardableResult
    static func write(
        _ definition: GhosttyThemeDefinition, into folder: URL, as fileName: String? = nil
    ) throws -> URL {
        let url = folder.appendingPathComponent(fileName ?? definition.name, isDirectory: false)
        try serialize(definition).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The Ghostty-format text for a definition. Palette entries are emitted in
    /// index order so the file is stable across writes and comparable byte for
    /// byte (see `removeRedundantCatalogCopies`).
    static func serialize(_ definition: GhosttyThemeDefinition) -> String {
        var lines: [String] = [
            "background = #\(definition.background)",
            "foreground = #\(definition.foreground)",
        ]
        if let cursorColor = definition.cursorColor { lines.append("cursor-color = #\(cursorColor)") }
        if let cursorText = definition.cursorText { lines.append("cursor-text = #\(cursorText)") }
        if let selectionBackground = definition.selectionBackground {
            lines.append("selection-background = #\(selectionBackground)")
        }
        if let selectionForeground = definition.selectionForeground {
            lines.append("selection-foreground = #\(selectionForeground)")
        }
        for index in definition.palette.keys.sorted() {
            guard let color = definition.palette[index] else { continue }
            lines.append("palette = \(index)=#\(color)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The folder's files in a stable order. Directory enumeration order is
    /// filesystem-dependent, so sorting by path is what makes the dedupe below
    /// deterministic rather than "whichever inode came back first".
    private static func sortedFiles() -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { !$0.hasDirectoryPath }
            .sorted { $0.path < $1.path }
    }

    private static func loadUserThemes() -> [GhosttyThemeDefinition] {
        var seen: Set<String> = []
        var result: [GhosttyThemeDefinition] = []
        for url in sortedFiles() {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // A theme's name is its file name (sans extension), matching how Ghostty
            // names themes after their file. Files may have no extension at all.
            guard let definition = parse(
                name: url.deletingPathExtension().lastPathComponent,
                contents: contents
            ) else { continue }
            // Two files can claim one name ("Dracula" and "Dracula.conf"). The
            // first in path order wins, and the rest are ignored rather than
            // shadowing each other differently on every launch.
            guard seen.insert(definition.name).inserted else { continue }
            result.append(definition)
        }
        return result
    }

    /// Parses one Ghostty-format theme file into a definition. Returns `nil` when
    /// the file lacks the background/foreground a usable theme needs. Hex values
    /// keep the catalog's bare (no leading `#`) convention so they flow through the
    /// existing `toTerminalConfiguration` and chrome-color paths unchanged.
    static func parse(name: String, contents: String) -> GhosttyThemeDefinition? {
        var background: String?
        var foreground: String?
        var cursorColor: String?
        var cursorText: String?
        var selectionBackground: String?
        var selectionForeground: String?
        var palette: [Int: String] = [:]

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Ghostty config comments begin a line with `#`; a `#` mid-line is the
            // start of a hex value, not a comment.
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "background": background = strippedHex(value)
            case "foreground": foreground = strippedHex(value)
            case "cursor-color": cursorColor = strippedHex(value)
            case "cursor-text": cursorText = strippedHex(value)
            case "selection-background": selectionBackground = strippedHex(value)
            case "selection-foreground": selectionForeground = strippedHex(value)
            case "palette":
                // The value is itself `index=#hex`.
                guard let equals = value.firstIndex(of: "=") else { continue }
                let indexText = value[..<equals].trimmingCharacters(in: .whitespaces)
                let colorText = value[value.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                if let index = Int(indexText) {
                    palette[index] = strippedHex(colorText)
                }
            default:
                continue
            }
        }

        guard let background, let foreground else { return nil }
        return GhosttyThemeDefinition(
            name: name,
            background: background,
            foreground: foreground,
            cursorColor: cursorColor,
            cursorText: cursorText,
            selectionBackground: selectionBackground,
            selectionForeground: selectionForeground,
            palette: palette
        )
    }

    /// Drops a leading `#` so parsed hex matches the bundled catalog's bare form.
    private static func strippedHex(_ value: String) -> String {
        value.hasPrefix("#") ? String(value.dropFirst()) : value
    }
}
