import Foundation

/// Reads the errors compilers, type checkers and linters print into a terminal, and the
/// lines that say a build came out clean.
///
/// fyolo runs no language servers; the build an agent or a person runs in a session is
/// already the authority on whether a file compiles, and it says so in a handful of
/// shapes nearly every toolchain shares. This recognizes those shapes in the raw output
/// stream — escape sequences stripped, lines reassembled — and nothing more: it never
/// runs a tool of its own.
///
/// Only *errors* count. A warning, a lint hint or a failing assertion's stack is not a
/// file that fails to build.
///
/// Pure state with no I/O, fed in whatever chunks the stream arrives in, so every format
/// is pinned by a test.
struct TerminalDiagnosticScanner {
    enum Event: Equatable {
        /// An error naming `path`, exactly as printed — relative paths are resolved
        /// later, against the session's working directory.
        case error(path: String)
        /// A build or check finished with no errors.
        case clean
    }

    /// A line longer than this is a minified bundle or a progress bar, not a diagnostic.
    private static let lineLimit = 4096

    private var line: [UInt8] = []
    private var lineOverflowed = false
    private var carriageReturn = false
    private var escape = EscapeState.none

    /// An error header seen with its location still to come (`error[E0425]: …` then
    /// `--> src/main.rs:2:5`), and how many lines it may wait.
    private var pendingHeader: (isError: Bool, linesLeft: Int)?
    /// The innermost frame of a Python traceback or an OCaml location, waiting for the
    /// line that says what kind of error it was.
    private var pendingFrame: (path: String, linesLeft: Int)?
    /// ESLint's stylish format names the file on a line of its own, then lists problems.
    private var currentFile: String?

    private enum EscapeState {
        case none
        case escape
        case controlSequence
        case string
        case stringEscape
    }

    mutating func feed(_ data: Data) -> [Event] {
        var events: [Event] = []
        for byte in data {
            switch escape {
            case .escape:
                switch byte {
                case UInt8(ascii: "["): escape = .controlSequence
                case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "X"),
                     UInt8(ascii: "^"), UInt8(ascii: "_"):
                    escape = .string
                default: escape = .none
                }
                continue
            case .controlSequence:
                guard (0x40...0x7E).contains(byte) else { continue }
                escape = .none
                // Cursor moves to another row, and screen clears, end what was being
                // written: a TUI draws its rows with these rather than with newlines.
                if "ABEFHfJd".utf8.contains(byte) { finishLine(into: &events) }
                continue
            case .string:
                if byte == 0x07 { escape = .none } else if byte == 0x1B { escape = .stringEscape }
                continue
            case .stringEscape:
                escape = byte == UInt8(ascii: "\\") ? .none : .string
                continue
            case .none:
                break
            }
            switch byte {
            case 0x1B:
                escape = .escape
            case UInt8(ascii: "\n"):
                finishLine(into: &events)
            case UInt8(ascii: "\r"):
                carriageReturn = true
            case UInt8(ascii: "\t"):
                append(UInt8(ascii: " "))
            case 0..<0x20, 0x7F:
                continue
            default:
                append(byte)
            }
        }
        return events
    }

    private mutating func append(_ byte: UInt8) {
        // A carriage return not followed by a newline rewrites the line in place.
        if carriageReturn {
            carriageReturn = false
            line.removeAll(keepingCapacity: true)
            lineOverflowed = false
        }
        guard line.count < Self.lineLimit else {
            lineOverflowed = true
            return
        }
        line.append(byte)
    }

    private mutating func finishLine(into events: inout [Event]) {
        carriageReturn = false
        defer {
            line.removeAll(keepingCapacity: true)
            lineOverflowed = false
        }
        guard !lineOverflowed, !line.isEmpty else { return }
        if let event = scan(String(decoding: line, as: UTF8.self)) { events.append(event) }
    }

    // MARK: Lines

    /// Characters a TUI or a box-drawing reporter puts before the text: Claude Code's
    /// `⎿`, Terraform's `│`, list bullets.
    private static let decoration = CharacterSet.whitespaces
        .union(CharacterSet(charactersIn: "│┃┆╎║⎿⏺●•›»▏▎|"))

    mutating func scan(_ raw: String) -> Event? {
        let text = raw.trimmingCharacters(in: Self.decoration)
        guard !text.isEmpty else { return nil }
        let header = pendingHeader.map { ($0.isError, $0.linesLeft - 1) }
        pendingHeader = header.flatMap { $0.1 > 0 ? $0 : nil }
        let frame = pendingFrame.map { ($0.path, $0.linesLeft - 1) }
        pendingFrame = frame.flatMap { $0.1 > 0 ? $0 : nil }

        if Self.matches(Self.clean, text) {
            resetPending()
            return .clean
        }

        // Python and OCaml: a location, then — a few lines on — the kind of error.
        if text.hasPrefix("Traceback (most recent call last)") {
            pendingFrame = nil
            return nil
        }
        if let path = Self.capture(Self.frame, text) {
            if !path.contains("/site-packages/"), !path.contains("/lib/python"), !path.hasPrefix("<") {
                pendingFrame = (path, 6)
            }
            return nil
        }
        if let frame = pendingFrame, Self.matches(Self.frameError, text) {
            pendingFrame = nil
            return .error(path: frame.path)
        }

        // Most toolchains say it all on one line.
        if let path = Self.firstCapture(Self.singleLine, text) {
            pendingHeader = nil
            return .error(path: path)
        }

        // Rust, Elixir, Deno, esbuild, Terraform: a header, then the location.
        if Self.matches(Self.errorHeader, text) {
            pendingHeader = (true, 12)
            return nil
        }
        if Self.matches(Self.warningHeader, text) {
            pendingHeader = (false, 12)
            return nil
        }
        if let header = pendingHeader, let path = Self.capture(Self.headerLocation, text) {
            pendingHeader = nil
            // A warning's own one-line report, landing under an earlier error header,
            // is still a warning.
            return header.isError && !text.localizedCaseInsensitiveContains("warning") ? .error(path: path) : nil
        }

        // ESLint: a file on its own line, then `12:5  error  message  rule`.
        if let path = Self.capture(Self.bareFile, text) {
            currentFile = path
            return nil
        }
        if let file = currentFile, Self.matches(Self.stylishError, text) {
            return .error(path: file)
        }
        if text.hasPrefix("✖") { currentFile = nil }
        return nil
    }

    private mutating func resetPending() {
        pendingHeader = nil
        pendingFrame = nil
        currentFile = nil
    }

    // MARK: Patterns

    /// A file path with an extension: absolute (and allowed spaces, which home folders
    /// have), or relative and space-free so prose does not read as a path.
    private static let path = #"((?:/[^\x00:\n]*?|(?:\.{1,2}/|~/)?[A-Za-z0-9_@+\-][^\s:()\[\]'"`,]*?)\.[A-Za-z0-9_+\-]{1,12})"#
    /// What may stand right before a path.
    private static let lead = #"(?:^|[\s(\[`'"])"#

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are literals in this file; one that fails to compile is a bug a
        // test catches, and an empty expression simply matches nothing in a release.
        (try? NSRegularExpression(pattern: pattern)) ?? NSRegularExpression()
    }

    /// The one-line shapes, each capturing the path in its first group that matched.
    private static let singleLine: [NSRegularExpression] = [
        // GNU and everything that copied it — gcc, clang, swiftc, javac, ghc, zig, dart,
        // mypy, ruby — and the ` - error` form of tsc's pretty output and pyright.
        regex(lead + path + #":(\d+)(?::(\d+))?(?::|\s+-)\s*(?:fatal\s+|syntax\s+)?(?i:error)\b"#),
        // MSBuild, C#, tsc's plain output, Nim: `file(12,5): error`.
        regex(lead + path + #"\((\d+),\s*(\d+)\):?\s*(?i:error)\b"#),
        // Kotlin: `e: file:///x/Foo.kt:12:5 message`, and the older `e: /x/Foo.kt: (12, 5)`.
        regex(#"^e:\s+(?:file://)?"# + path + #":\s*\(?\d+"#),
        // sbt and Maven: `[error] /x/Foo.scala:12:5:`, `[ERROR] /x/Foo.java:[12,5]`.
        regex(#"^\[(?:error|ERROR)\]\s+(?:file://)?"# + path + #":\[?\d+"#),
        // PHP: `Parse error: … in /x/index.php on line 12`.
        regex(#"(?i:parse|fatal) error:.*? in "# + path + #" on line \d+"#),
        // CMake.
        regex(#"CMake Error at "# + path + #":\d+"#),
        // webpack: `ERROR in ./src/index.ts 12:5-10`.
        regex(#"^ERROR in "# + path + #"(?:[\s:]|$)"#),
        // Go reports compile errors with no severity word at all.
        regex(lead + #"((?:/[^\x00:\n]*?|(?:\.{1,2}/)?[A-Za-z0-9_@+\-][^\s:()\[\]'"`,]*?)\.go):(\d+):(\d+): "#),
    ]

    /// A severity on a line of its own, with the location on a later line.
    private static let errorHeader = regex(#"^(?:✘\s*)?(?:(?i:error)(?:\[[\w\-]+\])?:|\[ERROR\])"#)
    private static let warningHeader = regex(#"^(?:▲\s*)?(?:(?i:warning)(?:\[[\w\-]+\])?:|\[WARNING\])"#)
    private static let headerLocation = regex(
        #"^(?:-->|└─|╭─\[|at\s+(?:file://)?|on\s+)?\s*"# + path + #"(?::\d+|\s+line\s+\d+)"#)

    private static let frame = regex(#"^File ""# + #"([^"]+)"# + #"", line \d+"#)
    /// The kind of error that ends a traceback, counted only when it means the file
    /// itself is broken — a runtime `KeyError` is a bug in the data, not the source.
    private static let frameError = regex(#"^(?:SyntaxError|IndentationError|TabError|Error)(?::|$)"#)

    private static let bareFile = regex(#"^"# + path + #"$"#)
    private static let stylishError = regex(#"^\d+:\d+\s+error\s"#)

    /// What builds print when they finish clean. Kept to phrases that cannot occur in a
    /// failed run: SwiftPM, xcodebuild, Gradle, Cargo, tsc's watch mode, webpack, mypy,
    /// and pyright's `0 errors`.
    private static let clean = regex(
        #"^Build complete!|\*\* BUILD SUCCEEDED \*\*|^BUILD SUCCESSFUL\b|^Finished\b.*\b(?:profile|target)|Found 0 errors\b|[Cc]ompiled successfully\b|^Success: no issues found|^0 errors\b"#)

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func capture(_ expression: NSRegularExpression, _ text: String) -> String? {
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func firstCapture(_ expressions: [NSRegularExpression], _ text: String) -> String? {
        // Cheap test first: nearly every line of output is not a diagnostic.
        guard text.contains("rror") || text.contains("e: ") || text.contains(".go:")
                || text.contains("ERROR")
        else { return nil }
        for expression in expressions {
            if let path = capture(expression, text) { return path }
        }
        return nil
    }
}

/// The files terminal output has reported errors in, by machine — what the file tree
/// underlines.
///
/// A report is only as good as the build that printed it, so this mostly decides when one
/// stops being true:
///
/// - **The file changes.** Fixing an error means editing the file; once it moves, the
///   report is about a version that is gone.
/// - **The session reports a fresh set.** A rebuild lists every error that still stands,
///   so findings that arrive after a quiet spell replace that session's earlier ones
///   instead of piling on top of them.
/// - **The session's build comes out clean.**
@MainActor
final class TerminalDiagnostics: ObservableObject {
    static let shared = TerminalDiagnostics()

    @Published private(set) var revision = 0

    /// What a session's output is resolved against.
    struct Context {
        /// `Checkout.deviceIdentity` of the machine the session runs on.
        let deviceIdentity: String
        /// Where a relative path in its output starts from.
        let workingDirectory: String?
        let isLocal: Bool
    }

    private struct Record {
        let session: Session.ID
        /// The file's modification date when the error was reported, on this Mac.
        let modified: Date?
    }

    /// Device identity → absolute path → the report.
    private var records: [String: [String: Record]] = [:]
    private var lastFinding: [Session.ID: Date] = [:]

    /// Findings further apart than this are two runs, not one run's output.
    private static let runGap: TimeInterval = 8
    /// A runaway build is not allowed to grow this without bound.
    private static let recordLimit = 5_000

    private nonisolated static let queue = DispatchQueue(label: "sh.fyolo.terminal-diagnostics", qos: .utility)

    /// One session's scanner, only ever touched on `queue`.
    private final class Tap: @unchecked Sendable {
        var scanner = TerminalDiagnosticScanner()
    }

    /// A sink for a session's live output. Called on the link's reader thread: it copies
    /// nothing but the chunk reference and returns, so the bytes reach the surface
    /// exactly as fast as they did without it.
    func tap(
        session: Session.ID,
        context: @escaping @MainActor @Sendable () -> Context?
    ) -> @Sendable (Data) -> Void {
        let tap = Tap()
        return { data in
            Self.queue.async {
                let events = tap.scanner.feed(data)
                guard !events.isEmpty else { return }
                Task { @MainActor in
                    guard let context = context() else { return }
                    TerminalDiagnostics.shared.apply(events, from: session, in: context)
                }
            }
        }
    }

    func apply(_ events: [TerminalDiagnosticScanner.Event], from session: Session.ID, in context: Context) {
        var changed = false
        let now = Date()
        for event in events {
            switch event {
            case .clean:
                changed = forget(session: session) || changed
                lastFinding[session] = nil
            case .error(let printed):
                guard let path = Self.resolve(printed, from: context.workingDirectory, isLocal: context.isLocal)
                else { continue }
                if let last = lastFinding[session], now.timeIntervalSince(last) > Self.runGap {
                    changed = forget(session: session) || changed
                }
                lastFinding[session] = now
                var modified: Date?
                if context.isLocal {
                    // A path that is not a file here is a misread, not an error to show.
                    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                          attributes[.type] as? FileAttributeType == .typeRegular
                    else { continue }
                    modified = attributes[.modificationDate] as? Date
                }
                var onDevice = records[context.deviceIdentity] ?? [:]
                guard onDevice[path]?.session != session || onDevice[path]?.modified != modified else { continue }
                guard onDevice.count < Self.recordLimit || onDevice[path] != nil else { continue }
                onDevice[path] = Record(session: session, modified: modified)
                records[context.deviceIdentity] = onDevice
                changed = true
            }
        }
        if changed { revision &+= 1 }
    }

    @discardableResult
    private func forget(session: Session.ID) -> Bool {
        var changed = false
        for (device, onDevice) in records {
            let kept = onDevice.filter { $0.value.session != session }
            if kept.count != onDevice.count {
                records[device] = kept
                changed = true
            }
        }
        return changed
    }

    func errorFiles(onDevice device: String, under root: String) -> Set<String> {
        guard let onDevice = records[device] else { return [] }
        let base = root.hasSuffix("/") ? root : root + "/"
        return Set(onDevice.keys.filter { $0.hasPrefix(base) })
    }

    /// The device says these directories' contents moved. On this Mac a report stands
    /// until its file's modification date does; on another machine, where checking
    /// that is a round trip, a change in the file's folder is taken as the edit.
    func directoriesChanged(_ directories: [String], onDevice device: String, isLocal: Bool) {
        guard let onDevice = records[device], !onDevice.isEmpty else { return }
        let changedFolders = Set(directories)
        let kept = onDevice.filter { path, record in
            guard changedFolders.contains((path as NSString).deletingLastPathComponent) else { return true }
            return isLocal && Self.isUnchanged(path, since: record)
        }
        guard kept.count != onDevice.count else { return }
        records[device] = kept
        revision &+= 1
    }

    /// Re-checks every report on this Mac against its file: edits made while no tree was
    /// watching still retire the errors they fixed.
    func revalidate(onDevice device: String, isLocal: Bool) {
        guard isLocal, let onDevice = records[device], !onDevice.isEmpty else { return }
        let kept = onDevice.filter { Self.isUnchanged($0.key, since: $0.value) }
        guard kept.count != onDevice.count else { return }
        records[device] = kept
        revision &+= 1
    }

    private static func isUnchanged(_ path: String, since record: Record) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        return attributes[.modificationDate] as? Date == record.modified
    }

    /// `printed` as an absolute path: `file://` dropped, `~` expanded on this Mac, a
    /// relative path joined to the session's working directory, and `.`/`..` folded
    /// lexically — the path may name a file on another machine, so nothing here asks
    /// this Mac's disk what it resolves to.
    nonisolated static func resolve(_ printed: String, from workingDirectory: String?, isLocal: Bool) -> String? {
        var path = printed.hasPrefix("file://") ? String(printed.dropFirst("file://".count)) : printed
        if path.hasPrefix("~/") {
            guard isLocal else { return nil }
            path = NSHomeDirectory() + path.dropFirst()
        }
        if !path.hasPrefix("/") {
            guard let workingDirectory, workingDirectory.hasPrefix("/") else { return nil }
            path = workingDirectory + "/" + path
        }
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": _ = components.popLast()
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }
}
