import Foundation

/// The slice of a user's Ghostty configuration fyolo inherits: font and theme. Parsed once at
/// launch and layered *under* fyolo's own settings via the UserDefaults registration domain
/// (see `AppSettings.init`) — a value set in fyolo always wins, Ghostty fills what fyolo never
/// touched, and the built-in defaults back both. No Ghostty install means an empty config and
/// the built-ins stand untouched.
///
/// Only top-level `key = value` lines are read; `config-file` includes are deliberately not
/// followed — this is a launch-time convenience, not a reimplementation of Ghostty's loader.
struct GhosttyUserConfig {
    /// `theme` as written — the *form* matters downstream: a bare name is Ghostty's
    /// "one theme regardless of appearance" (fyolo inherits it only into the appearance it
    /// belongs to), while the `light:Name,dark:Name` split form names each slot explicitly
    /// (fyolo honors both slots verbatim, even when the two names are equal).
    enum ThemeSetting: Equatable {
        case bare(String)
        case split(light: String, dark: String)
    }

    /// `font-family` values in declaration order — Ghostty treats repeats as a fallback chain
    /// and an empty value as a chain reset. The first entry is the primary face.
    var fontFamilies: [String] = []
    var fontSize: Double?
    var themeSetting: ThemeSetting?

    var isEmpty: Bool { fontFamilies.isEmpty && fontSize == nil && themeSetting == nil }

    /// Mirrors Ghostty's `Theme.parseCLI`: a comma, colon, or equals sign switches to the
    /// light/dark pair form, and the pair form is all-or-nothing — every part must be a
    /// `light:`/`dark:` pair and both slots must end up named, or Ghostty rejects the whole
    /// line as a config error. Returning nil mirrors that rejection, and it matters as much
    /// as the parse: a line Ghostty errors on paints nothing there, so fyolo must not
    /// inherit it either.
    static func parseThemeSetting(_ value: String) -> ThemeSetting? {
        guard value.contains(",") || value.contains(":") || value.contains("=") else {
            return .bare(value)
        }
        var light: String?
        var dark: String?
        for part in value.split(separator: ",") {
            let pair = part.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { return nil }
            let mode = pair[0].trimmingCharacters(in: .whitespaces)
            var name = pair[1].trimmingCharacters(in: .whitespaces)
            if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") {
                name = String(name.dropFirst().dropLast())
            }
            switch mode {
            case "light": light = name
            case "dark": dark = name
            default: return nil
            }
        }
        guard let light, let dark else { return nil }
        return .split(light: light, dark: dark)
    }

    /// Reads the files Ghostty itself loads on macOS, in Ghostty's order — XDG before
    /// Application Support, and in each place the legacy `config` before the `config.ghostty`
    /// name Ghostty prefers since 1.3 — so later files win for single-value keys while
    /// `font-family` keeps accumulating across all of them.
    static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> GhosttyUserConfig {
        let xdgBase = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config")
        let appSupportBase = home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty")
        let paths = [
            xdgBase.appendingPathComponent("ghostty/config"),
            xdgBase.appendingPathComponent("ghostty/config.ghostty"),
            appSupportBase.appendingPathComponent("config"),
            appSupportBase.appendingPathComponent("config.ghostty"),
        ]
        var config = GhosttyUserConfig()
        for path in paths {
            guard let text = try? String(contentsOf: path, encoding: .utf8) else { continue }
            config.merge(parsing: text)
        }
        return config
    }

    /// Folds one config file's text into the receiver: later lines win for single-value keys,
    /// `font-family` accumulates, comments and unknown keys are skipped.
    mutating func merge(parsing text: String) {
        // Split on `isNewline`, not "\n": Swift folds "\r\n" into one grapheme cluster, so a
        // CRLF-saved config would otherwise never split into lines at all.
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            // Keys stay case-sensitive because Ghostty's are.
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "font-family":
                if value.isEmpty {
                    fontFamilies = []
                } else if !fontFamilies.contains(value) {
                    // Deduped: Ghostty's two config files often repeat the same face, and a
                    // duplicate fallback buys nothing.
                    fontFamilies.append(value)
                }
            case "font-size":
                fontSize = Double(value)
            case "theme":
                if value.isEmpty {
                    themeSetting = nil
                } else if let setting = Self.parseThemeSetting(value) {
                    themeSetting = setting
                }
                // An unparsable value keeps the previous one: Ghostty rejects the bad
                // line as a config error and the earlier setting stays in effect.
            default:
                break
            }
        }
    }
}
