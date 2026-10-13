import Foundation

/// Run buttons for a `package.json`'s scripts: a ▶ beside each entry under
/// `"scripts"` that runs it with the project's own package manager, in the
/// package's folder, in a fyolo terminal.
struct PackageScriptsPlugin: FyoloPlugin {
    let id = "package-scripts"
    let name = "package.json Scripts"
    var summary: String {
        localized("A run button beside each script in a package.json, using the project’s package manager.")
    }

    func gutterActions(for file: URL, text: String) -> [GutterAction] {
        guard file.lastPathComponent == "package.json" else { return [] }
        let scripts = Self.scriptLines(in: text)
        guard !scripts.isEmpty else { return [] }
        let directory = file.deletingLastPathComponent()
        let manager = Self.packageManager(declared: Self.declaredPackageManager(in: text), near: directory)
        return scripts.map { script in
            let command = "\(manager) run \(RunTask.shellWord(script.name))"
            return GutterAction(
                line: script.line,
                help: command,
                command: .run(RunTask(name: script.name, command: command, directory: directory))
            )
        }
    }

    // MARK: Finding the scripts

    /// Each key of the top-level `"scripts"` object with the line it starts on.
    ///
    /// A scan rather than `JSONSerialization`, which has no line numbers and
    /// gives up on the whole file at the first stray comma — and a buffer being
    /// edited is invalid JSON half the time. The scan only tracks strings, nesting
    /// and keys, so the buttons stay put while the user types.
    static func scriptLines(in text: String) -> [(name: String, line: Int)] {
        let bytes = Array(text.utf8)
        var results: [(name: String, line: Int)] = []
        var index = 0
        var line = 1
        var depth = 0
        var scriptsDepth: Int?
        var expectingScriptsObject = false

        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                let startLine = line
                let start = index + 1
                index += 1
                while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                    if bytes[index] == UInt8(ascii: "\\") { index += 1 }
                    index += 1
                }
                let raw = bytes[start..<min(index, bytes.count)]
                index += 1
                // A key is a string the next non-space byte turns into `"key":`.
                var lookahead = index
                while lookahead < bytes.count, isWhitespace(bytes[lookahead]) {
                    if bytes[lookahead] == UInt8(ascii: "\n") { line += 1 }
                    lookahead += 1
                }
                index = lookahead
                let isKey = lookahead < bytes.count && bytes[lookahead] == UInt8(ascii: ":")
                guard isKey else {
                    expectingScriptsObject = false
                    continue
                }
                let key = decodeString(raw)
                if depth == 1, key == "scripts" {
                    expectingScriptsObject = true
                } else if let scriptsDepth, depth == scriptsDepth, let key {
                    results.append((key, startLine))
                }
                continue
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                if expectingScriptsObject, byte == UInt8(ascii: "{"), depth == 2 {
                    scriptsDepth = depth
                }
                expectingScriptsObject = false
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if depth == scriptsDepth { return results }
                depth -= 1
            case UInt8(ascii: "\n"):
                line += 1
            case UInt8(ascii: ":"), UInt8(ascii: ","):
                break
            default:
                if !isWhitespace(byte) { expectingScriptsObject = false }
            }
            index += 1
        }
        return results
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// A JSON string's contents with its escapes resolved.
    private static func decodeString(_ raw: ArraySlice<UInt8>) -> String? {
        let quoted = Data([UInt8(ascii: "\"")] + raw + [UInt8(ascii: "\"")])
        return try? JSONDecoder().decode(String.self, from: quoted)
    }

    // MARK: Choosing the package manager

    /// The manager `package.json` names in its `packageManager` field
    /// (`"pnpm@9.1.0"` → `pnpm`), which Corepack treats as authoritative.
    static func declaredPackageManager(in text: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let declared = object["packageManager"] as? String,
              let name = declared.split(separator: "@").first.map(String.init),
              knownManagers.contains(name)
        else { return nil }
        return name
    }

    private static let knownManagers: Set<String> = ["npm", "pnpm", "yarn", "bun"]

    /// Lockfiles name the manager that wrote them. A workspace keeps its single
    /// lockfile at the repository root, so the search walks up from the package.
    private static let lockfiles: [(file: String, manager: String)] = [
        ("pnpm-lock.yaml", "pnpm"),
        ("yarn.lock", "yarn"),
        ("bun.lock", "bun"),
        ("bun.lockb", "bun"),
        ("package-lock.json", "npm"),
    ]

    static func packageManager(declared: String?, near directory: URL) -> String {
        if let declared { return declared }
        // Walked as path strings: `URL("/").deletingLastPathComponent()` is `/../`,
        // not `/`, so a URL walk never sees the root and never stops.
        var current = directory.standardizedFileURL.path
        while true {
            for lockfile in lockfiles
            where FileManager.default.fileExists(atPath: (current as NSString).appendingPathComponent(lockfile.file)) {
                return lockfile.manager
            }
            guard current != "/", !current.isEmpty else { return "npm" }
            current = (current as NSString).deletingLastPathComponent
        }
    }
}
