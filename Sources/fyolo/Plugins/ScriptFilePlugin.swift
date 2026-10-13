import Foundation

/// Runs a script as a whole: a ▶ on line 1 of a shell file, or of any file that
/// opens with a `#!`, and a "Run in Integrated Terminal" row on its right-click
/// menu in the file tree.
struct ScriptFilePlugin: FyoloPlugin {
    let id = "script-files"
    let name = "Script Files"
    var summary: String {
        localized("Run a shell script, or any file that starts with #!, from its first line or the file tree.")
    }

    private static let shellsByExtension = ["sh": "sh", "bash": "bash", "zsh": "zsh"]

    func gutterActions(for file: URL, text: String) -> [GutterAction] {
        guard let task = Self.task(for: file, firstLine: Self.firstLine(of: text)) else { return [] }
        return [GutterAction(line: 1, help: task.command, command: .run(task))]
    }

    func wholeFileTask(for file: URL) -> RunTask? {
        Self.task(for: file, firstLine: Self.firstLine(ofFileAt: file))
    }

    /// How `file` runs, given its first line: through the `#!` interpreter when
    /// there is one — exactly what the kernel would exec — else through the shell
    /// its extension names. Passing the path to the interpreter rather than
    /// executing the file leaves the exec bit out of it.
    ///
    /// It runs from the repository root with a repo-relative path, because scripts
    /// like `scripts/build-app.sh` are written to be run from there; outside a
    /// repository, from the file's own folder.
    static func task(for file: URL, firstLine: String?, root: URL? = nil) -> RunTask? {
        let interpreter: String
        if let firstLine, firstLine.hasPrefix("#!") {
            let line = firstLine.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            interpreter = line
        } else if let shell = shellsByExtension[file.pathExtension.lowercased()] {
            interpreter = shell
        } else {
            return nil
        }
        let directory = root ?? GitRoot.find(for: file) ?? file.deletingLastPathComponent()
        let command = "\(interpreter) \(RunTask.shellWord(relativePath(of: file, from: directory)))"
        return RunTask(name: file.lastPathComponent, command: command, directory: directory)
    }

    /// `file` relative to `directory` when it sits inside it, else its full path.
    static func relativePath(of file: URL, from directory: URL) -> String {
        let base = directory.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return path }
        return String(path.dropFirst(base.count + 1))
    }

    private static func firstLine(of text: String) -> String? {
        text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
    }

    /// The file's first line, read without loading the file: a `#!` line is short,
    /// and the context menu asks this of whatever row was clicked, binaries included.
    private static func firstLine(ofFileAt file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512) else { return nil }
        // Lossy on purpose: 512 bytes can end mid-character, and only the first line matters.
        return firstLine(of: String(decoding: data, as: UTF8.self))
    }
}
