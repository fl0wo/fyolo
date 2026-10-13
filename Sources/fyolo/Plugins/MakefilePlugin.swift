import Foundation

/// Run buttons for a Makefile's targets: a ▶ beside each rule that runs
/// `make <target>` in the Makefile's folder, in a fyolo terminal.
struct MakefilePlugin: FyoloPlugin {
    let id = "make-targets"
    let name = "Makefile Targets"
    var summary: String {
        localized("A run button beside each target in a Makefile.")
    }

    /// The names `make` reads without `-f`, in its own lookup order.
    private static let defaultNames: Set<String> = ["GNUmakefile", "makefile", "Makefile"]

    static func isMakefile(_ file: URL) -> Bool {
        defaultNames.contains(file.lastPathComponent) || file.pathExtension == "mk"
    }

    func gutterActions(for file: URL, text: String) -> [GutterAction] {
        guard Self.isMakefile(file) else { return [] }
        let targets = Self.targetLines(in: text)
        guard !targets.isEmpty else { return [] }
        let directory = file.deletingLastPathComponent()
        let fileName = file.lastPathComponent
        let make = Self.defaultNames.contains(fileName) ? "make" : "make -f \(RunTask.shellWord(fileName))"
        return targets.map { target in
            let command = "\(make) \(RunTask.shellWord(target.name))"
            return GutterAction(
                line: target.line,
                help: command,
                command: .run(RunTask(name: target.name, command: command, directory: directory))
            )
        }
    }

    /// The first target named on each rule line, with that line's number.
    ///
    /// A line scan rather than a make parser, for the reason the package.json
    /// scan gives: the buffer is half-edited most of the time, and the buttons
    /// should stay put while the user types. It skips what can't be run by
    /// name — recipes, variable assignments, `define` bodies, continuation
    /// lines, special targets like `.PHONY`, pattern rules and computed names.
    static func targetLines(in text: String) -> [(name: String, line: Int)] {
        var results: [(name: String, line: Int)] = []
        var insideDefine = false
        var continues = false
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
            let continuedFromAbove = continues
            continues = line.hasSuffix("\\")
            if continuedFromAbove { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if insideDefine {
                if trimmed == "endef" || trimmed.hasPrefix("endef ") { insideDefine = false }
                continue
            }
            if trimmed.hasPrefix("define ") || trimmed == "define" {
                insideDefine = true
                continue
            }
            guard let first = line.first, first != "\t", first != " ", first != "#",
                  let target = ruleTarget(in: line)
            else { continue }
            results.append((target, index + 1))
        }
        return results
    }

    /// The first name before a rule's `:`, or `nil` when the line is not a rule
    /// with a runnable name.
    private static func ruleTarget(in line: Substring) -> String? {
        let code = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? line
        guard let colon = code.firstIndex(of: ":") else { return nil }
        let before = code[..<colon]
        let after = code[code.index(after: colon)...]
        // `A := x` and `A ::= x` assign; `A ?= x`, `A += x` and `A = x` never reach
        // a colon before their `=`, but `A = x:y` does, so any `=` ahead of the
        // colon means an assignment too.
        if after.hasPrefix("=") || after.hasPrefix(":=") || before.contains("=") { return nil }
        guard let name = before.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init),
              !name.hasPrefix("."), !name.contains("%"), !name.contains("$")
        else { return nil }
        return name
    }
}
