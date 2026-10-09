import Foundation
#if canImport(Highlightr)
    import Highlightr
#endif

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// Syntax highlighting shared by both platforms: the same Highlightr
/// (highlight.js) engine and xcode/xcode-dark themes the macOS editor uses,
/// so a file opened on the phone reads like the same file on the Mac.
///
/// The Highlightr package is an iOS-only dependency here (the macOS app
/// vendors it — see Shared/Package.swift), so `highlight` is compiled out on
/// macOS; only the pure `language(forFileNamed:)` sniffing is cross-platform.
public enum CodeHighlighter {
    #if canImport(Highlightr)
    /// Highlight `code` into an attributed string with a monospaced font.
    /// `language` nil lets highlight.js auto-detect. Heavy-ish (spins up a
    /// JavaScriptCore context) — call off the main thread and once per open,
    /// not per keystroke.
    public static func highlight(
        _ code: String,
        language: String?,
        dark: Bool,
        fontSize: CGFloat
    ) -> NSAttributedString? {
        guard let highlightr = Highlightr() else { return nil }
        highlightr.setTheme(to: dark ? "xcode-dark" : "xcode")
        highlightr.theme.setCodeFont(.monospacedSystemFont(ofSize: fontSize, weight: .regular))
        return highlightr.highlight(code, as: language)
    }
    #endif

    /// The highlight.js language id for a file name — extension-based with a
    /// carve-out for specially-named extension-less files (Dockerfile,
    /// Makefile, …). Mirrors the macOS editor's sniffing.
    public static func language(forFileNamed fileName: String) -> String? {
        switch fileName.lowercased() {
        case "dockerfile", "containerfile": return "dockerfile"
        case "makefile", "gnumakefile": return "makefile"
        case "cmakelists.txt": return "cmake"
        case "gemfile", "podfile", "rakefile", "gemfile.lock": return "ruby"
        case "cargo.lock", "poetry.lock", "pipfile": return "ini" // TOML-ish (no toml grammar)
        case "yarn.lock": return "yaml"
        case ".gitignore", ".dockerignore", ".npmignore": return "bash"
        case ".env", ".editorconfig", ".npmrc": return "ini"
        case "nginx.conf": return "nginx"
        default: break
        }

        switch (fileName as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "js", "mjs", "cjs", "jsx": return "javascript"
        case "ts", "tsx", "mts", "cts": return "typescript"
        case "py", "pyw", "pyi": return "python"
        case "rb": return "ruby"
        case "go": return "go"
        case "rs": return "rust"
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp", "hh", "hxx": return "cpp"
        case "m", "mm": return "objectivec"
        case "cs": return "csharp"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "php": return "php"
        case "dart": return "dart"
        case "lua": return "lua"
        case "r": return "r"
        case "scala", "sc": return "scala"
        case "hs": return "haskell"
        case "ex", "exs": return "elixir"
        case "erl", "hrl": return "erlang"
        case "clj", "cljs", "edn": return "clojure"
        case "pl", "pm": return "perl"
        // JSON family — highlight.js has no jsonc/json5 grammar, so they fold
        // into json. Most `.lock` files are JSON too.
        case "json", "jsonc", "json5", "lock": return "json"
        case "yml", "yaml": return "yaml"
        case "toml", "ini", "conf", "cfg", "properties": return "ini"
        case "md", "markdown", "mdx": return "markdown"
        case "sh", "bash", "zsh", "fish", "ksh": return "bash"
        case "ps1", "psm1": return "powershell"
        case "bat", "cmd": return "dos"
        case "html", "htm", "xml", "plist", "svg", "xhtml": return "xml"
        case "css": return "css"
        case "scss", "sass": return "scss"
        case "less": return "less"
        case "sql": return "sql"
        case "graphql", "gql": return "graphql"
        case "proto": return "protobuf"
        case "cmake": return "cmake"
        case "mk", "mak": return "makefile"
        case "diff", "patch": return "diff"
        default: return nil
        }
    }
}
