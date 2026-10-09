import Foundation

/// The outcome of a non-interactive SSH reachability + auth probe (the Settings
/// "Test Connection" action). Deliberately coarse: enough to tell "it works"
/// from "the network’s the problem" from "auth’s the problem", each with a short
/// human line for the row and the raw detail in a tooltip.
enum SSHProbeResult: Equatable {
    case reachable
    /// The server offered password (or keyboard-interactive) authentication and
    /// we declined to ask. Told apart from `authFailed` because it is the one
    /// failure with a one-click fix: install a key and the host works everywhere,
    /// including the paths that can never type a password (see
    /// `Fyolod.sshArguments`, where `BatchMode=yes` is unconditional).
    case wantsPassword(String)
    case authFailed(String)
    case unreachable(String)
}

enum SSHConfigWriteError: Error, LocalizedError {
    case valueContainsNewline

    var errorDescription: String? {
        switch self {
        case .valueContainsNewline:
            return localized("A line break can’t be written to ssh config.")
        }
    }
}

/// A `User` + `IdentityFile` pair already in use somewhere in `~/.ssh/config`.
///
/// Termius calls this an *identity* and keeps it in a synced credential vault;
/// this is the half of that idea which needs no store at all — the pairs are
/// derived from the config on every read, so picking one in Add Host is a
/// shortcut for typing what the user's other hosts already say. Nothing is
/// remembered that `ssh` itself doesn't already resolve.
struct SSHIdentity: Hashable, Identifiable {
    /// Empty when no block sets `User` — ssh falls back to the local username.
    let user: String
    /// `~`-relative and verbatim, as the config writes it; nil pins no key.
    let identityFile: String?

    var id: String { "\(user)\u{0}\(identityFile ?? "")" }

    /// The key's filename alone (`id_ed25519`), for a row that has no room for a
    /// path. Empty when the identity pins no key.
    var keyName: String {
        guard let identityFile else { return "" }
        return (identityFile as NSString).lastPathComponent
    }
}

/// One connectable `Host` block parsed from the user's OpenSSH client config —
/// the same aliases `ssh <alias>` itself resolves. A block that lists several
/// aliases yields one entry per alias. `file`/`line` locate the block's `Host`
/// line so the settings pane can jump straight to it in the editor.
struct SSHConfigHost: Identifiable, Hashable {
    let alias: String
    /// The block's `HostName`, falling back to the alias when the block sets none
    /// (which is how ssh resolves it too).
    let hostName: String
    let user: String
    let port: Int
    /// The block's first `IdentityFile`, verbatim (`~` unexpanded), when set.
    let identityFile: String?
    let file: URL
    let line: Int

    var id: String { "\(file.path)#\(line)#\(alias)" }

    /// The row caption under the alias: `user@host`, with the port only when it
    /// isn't ssh's default.
    var destinationLabel: String {
        let base = user.isEmpty ? hostName : "\(user)@\(hostName)"
        return port == 22 ? base : "\(base):\(port)"
    }
}

/// A public key sitting in `~/.ssh`, listed so its text is one click from the
/// clipboard (for a server's `authorized_keys`). Private keys are never read.
struct SSHPublicKey: Identifiable, Hashable {
    let url: URL
    /// The key's algorithm, prettified from the line's leading token.
    let algorithm: String
    /// The trailing comment (usually `user@machine`), empty when absent.
    let comment: String

    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

/// Reads and appends to the user's `~/.ssh/config`. The config file is the
/// single source of truth for SSH hosts — fyolo keeps no host database of its
/// own, so anything another tool (or the user, in any editor) writes there shows
/// up here, and anything added here works in a bare `ssh` immediately.
enum SSHConfigFile {
    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    }

    /// The config with symlinks resolved — dotfile managers commonly symlink
    /// `~/.ssh/config`, and an atomic write aimed at the link path would replace
    /// the link with a plain file, orphaning the managed target. Every write
    /// (and the in-app editor) goes through this.
    static var writableConfigURL: URL { configURL.resolvingSymlinksInPath() }

    /// The connectable hosts from `~/.ssh/config` and any `Include`d files,
    /// resolved the way ssh itself resolves them: blocks are replayed in file
    /// order and the *first obtained* value per key wins, so `Host *` defaults
    /// and wildcard blocks contribute exactly what a real `ssh <alias>` would
    /// use. (Known simplifications: `Match` blocks are skipped, and an
    /// `Include` splices at the top level rather than into a block's context.)
    static func hosts() -> [SSHConfigHost] {
        var visited: Set<String> = []
        // Directives before any Host/Match line apply unconditionally, exactly
        // as if they sat under `Host *`.
        var context: Block? = Block(patterns: ["*"], file: configURL, line: 0)
        var blocks = blocks(in: configURL, visited: &visited, depth: 0, context: &context)
        if let context { blocks.append(context) }
        var results: [SSHConfigHost] = []
        var seen: Set<String> = []
        for block in blocks {
            for alias in block.patterns
            where !alias.contains("*") && !alias.contains("?") && !alias.hasPrefix("!")
                && !seen.contains(alias) {
                seen.insert(alias)
                var hostName: String?, user: String?, identityFile: String?
                var port: Int?
                for candidate in blocks where matches(alias, patterns: candidate.patterns) {
                    if hostName == nil { hostName = candidate.hostName }
                    if user == nil { user = candidate.user }
                    if port == nil { port = candidate.port }
                    if identityFile == nil { identityFile = candidate.identityFile }
                }
                // ssh expands %h in HostName to the name given on the command
                // line (the alias) — `Host *.cloud` + `HostName %h.internal`.
                let expandedHostName = (hostName ?? alias)
                    .replacingOccurrences(of: "%%", with: "\u{0}")
                    .replacingOccurrences(of: "%h", with: alias)
                    .replacingOccurrences(of: "\u{0}", with: "%")
                results.append(SSHConfigHost(
                    alias: alias, hostName: expandedHostName, user: user ?? "",
                    port: port ?? 22, identityFile: identityFile,
                    file: block.file, line: block.line
                ))
            }
        }
        return results
    }

    /// One `Host` block in file order: its patterns plus the values its own
    /// lines set, kept unresolved so `hosts()` can replay ssh's
    /// first-obtained-value rule across blocks.
    private struct Block {
        var patterns: [String]
        var hostName: String?
        var user: String?
        var port: Int?
        var identityFile: String?
        var file: URL
        var line: Int
    }

    /// ssh_config pattern-list matching for one alias: any negated (`!`)
    /// pattern match excludes the block; otherwise any positive match includes.
    private static func matches(_ alias: String, patterns: [String]) -> Bool {
        var matched = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if wildcardMatches(String(pattern.dropFirst()), alias) { return false }
            } else if wildcardMatches(pattern, alias) {
                matched = true
            }
        }
        return matched
    }

    /// ssh's own pattern language: `*` and `?` only — deliberately not
    /// `fnmatch`, whose bracket classes would make `web[1-3]` match here while
    /// a real ssh treats the brackets literally.
    private static func wildcardMatches(_ pattern: String, _ candidate: String) -> Bool {
        let p = Array(pattern), c = Array(candidate)
        var pi = 0, ci = 0, star = -1, mark = 0
        while ci < c.count {
            if pi < p.count, p[pi] == "?" || p[pi] == c[ci] {
                pi += 1; ci += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = ci; pi += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; ci = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// Parses one file into blocks, threading the *current block* through
    /// `context` the way ssh splices `Include`: an included file's leading
    /// directives continue the including block, and a block left open at the
    /// file's end resumes in the includer (the top level flushes the last one).
    private static func blocks(
        in url: URL, visited: inout Set<String>, depth: Int, context: inout Block?
    ) -> [Block] {
        let path = url.standardizedFileURL.path
        // `visited` is the active recursion *stack*, not a permanent memo: a
        // shared file legitimately included under several Host blocks parses
        // once per inclusion; only a file currently being parsed (a cycle) is
        // refused. The depth cap breaks chains the stack can't catch.
        guard depth <= 3, !visited.contains(path),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        visited.insert(path)
        defer { visited.remove(path) }

        var blocks: [Block] = []
        // While true, the parse sits inside a Match block: its directives (and
        // its Includes, which ssh gates on the Match condition) are skipped
        // until the next Host, since this parser doesn't evaluate conditions.
        var inMatch = false

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = tokens(of: line)
            guard let keyword = parts.first?.lowercased() else { continue }
            let values = Array(parts.dropFirst())
            switch keyword {
            case "host":
                if let block = context { blocks.append(block) }
                context = Block(patterns: values, file: url, line: index + 1)
                inMatch = false
            case "match":
                if let block = context { blocks.append(block) }
                context = nil
                inMatch = true
            case "include" where !inMatch:
                for value in values {
                    for included in resolveInclude(value) {
                        blocks.append(contentsOf: Self.blocks(
                            in: included, visited: &visited, depth: depth + 1,
                            context: &context
                        ))
                    }
                }
            case "hostname": if context?.hostName == nil { context?.hostName = values.first }
            case "user": if context?.user == nil { context?.user = values.first }
            case "port": if context?.port == nil { context?.port = values.first.flatMap(Int.init) }
            case "identityfile": if context?.identityFile == nil { context?.identityFile = values.first }
            default: break
            }
        }
        return blocks
    }

    /// Splits an ssh_config line into tokens: whitespace/`=` separated, with
    /// double-quoted segments kept whole (ssh's own quoting for values that
    /// contain spaces — so the app can read back the blocks it writes). A `#`
    /// starting a token ends the line: ssh has no trailing comments, but a
    /// stray note should degrade to being ignored, not to bogus hosts.
    private static func tokens(of line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for character in line {
            if character == "\"" { inQuotes.toggle(); continue }
            if !inQuotes, character == " " || character == "\t" || character == "=" {
                if !current.isEmpty { tokens.append(current); current = "" }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { tokens.append(current) }
        if let hash = tokens.firstIndex(where: { $0.hasPrefix("#") }) {
            tokens = Array(tokens[..<hash])
        }
        return tokens
    }

    /// Expands one `Include` operand to concrete files: `~` and relative paths
    /// resolve per ssh_config(5) (relative means under `~/.ssh`), and a glob in
    /// the last path component matches directory entries via `fnmatch`.
    private static func resolveInclude(_ pattern: String) -> [URL] {
        var expanded = (pattern as NSString).expandingTildeInPath
        if !expanded.hasPrefix("/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ssh").appendingPathComponent(expanded).path
        }
        let url = URL(fileURLWithPath: expanded)
        let lastComponent = url.lastPathComponent
        guard lastComponent.contains("*") || lastComponent.contains("?") else { return [url] }
        let directory = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { fnmatch(lastComponent, $0, 0) == 0 }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    /// Creates `~/.ssh` (0700) and an empty config (0600) when missing — the
    /// permissions ssh itself insists on — so the editor and Add Host always have
    /// a real file to work with.
    static func ensureConfigExists() throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let target = writableConfigURL
        if !manager.fileExists(atPath: target.path) {
            manager.createFile(
                atPath: target.path, contents: Data(),
                attributes: [.posixPermissions: 0o600]
            )
        }
    }

    /// Appends a plain `Host` block to `~/.ssh/config`. Optional fields are
    /// simply omitted, and the default port is not written — the block stays as
    /// clean as one written by hand.
    static func appendHost(
        alias: String, hostName: String, user: String, port: String, identityFile: String
    ) throws {
        // A newline in any value ends the directive and lets whatever follows land
        // in the file as configuration of its own — a pasted address could append
        // its own `Host` block or a `ProxyCommand`. The sheet rejects it too; it is
        // refused here as well because this is what writes the file.
        guard ![alias, hostName, user, port, identityFile].contains(where: isUnwritable)
        else { throw SSHConfigWriteError.valueContainsNewline }
        // ssh_config quotes arguments that contain spaces (a picked key file
        // under "My Drive" must not split into two tokens). Values containing a
        // double quote are unrepresentable in ssh_config and rejected upstream
        // in the sheet.
        func quoted(_ value: String) -> String {
            value.contains(" ") ? "\"\(value)\"" : value
        }
        var block = "Host \(quoted(alias))\n  HostName \(quoted(hostName))\n"
        if !user.isEmpty { block += "  User \(quoted(user))\n" }
        if let portNumber = Int(port), portNumber != 22 { block += "  Port \(portNumber)\n" }
        if !identityFile.isEmpty { block += "  IdentityFile \(quoted(identityFile))\n" }

        try ensureConfigExists()
        let target = writableConfigURL
        var text = try String(contentsOf: target, encoding: .utf8)
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        if !text.isEmpty { text += "\n" }
        try (text + block).write(to: target, atomically: true, encoding: .utf8)
        // The atomic write lands as a fresh temp file, so re-assert the 0600 ssh
        // expects rather than inheriting the process umask.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: target.path
        )
    }

    /// The `*.pub` keys in `~/.ssh`, sorted by name. Unreadable or non-key files
    /// are skipped rather than surfaced — this list is a convenience, not an audit.
    static func publicKeys() -> [SSHPublicKey] {
        let directory = configURL.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".pub") }.sorted().compactMap { name in
            let url = directory.appendingPathComponent(name)
            guard let line = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else { return nil }
            let fields = line.split(separator: " ", maxSplits: 2).map(String.init)
            let algorithm: String
            switch fields.first ?? "" {
            case "ssh-ed25519": algorithm = "ED25519"
            case "ssh-rsa": algorithm = "RSA"
            case "ssh-dss": algorithm = "DSA"
            case let raw where raw.hasPrefix("sk-ssh-ed25519"): algorithm = "ED25519-SK"
            case let raw where raw.hasPrefix("sk-ecdsa"): algorithm = "ECDSA-SK"
            case let raw where raw.hasPrefix("ecdsa"): algorithm = "ECDSA"
            // Anything else isn't a public key line — including a `.pub`-named
            // symlink at a private key, which must never reach the clipboard.
            default: return nil
            }
            return SSHPublicKey(
                url: url, algorithm: algorithm,
                comment: fields.count > 2 ? fields[2] : ""
            )
        }
    }

    /// Probes an alias non-interactively: connect, authenticate, run `true`,
    /// exit — it never opens a shell or a prompt. `BatchMode=yes` blocks any
    /// password/passphrase ask (so it can't hang waiting on stdin),
    /// `ConnectTimeout` bounds the network wait, and running `true` makes a clean
    /// exit mean "authenticated and the remote executed a command". Runs off the
    /// main thread; the exact ssh resolution matches a real `ssh <alias>`.
    static func testConnection(alias: String) async -> SSHProbeResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = [
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=6",
                    // A never-seen host would otherwise fail the probe on the
                    // host-key prompt BatchMode suppresses; accept-new records it
                    // exactly as a first real connect would.
                    "-o", "StrictHostKeyChecking=accept-new",
                    alias, "true",
                ]
                let errorPipe = Pipe()
                process.standardError = errorPipe
                process.standardOutput = Pipe()
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .unreachable(localized("ssh unavailable")))
                    return
                }
                // Drain before wait: a full stderr pipe would deadlock a process
                // we're blocking on. EOF arrives when ssh exits and closes it.
                let stderr = String(
                    data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
                ) ?? ""
                process.waitUntilExit()
                continuation.resume(
                    returning: process.terminationStatus == 0 ? .reachable : classify(stderr)
                )
            }
        }
    }

    /// Buckets ssh's stderr into the probe outcomes, keeping the clearest line as
    /// the detail. Auth failures (including BatchMode's "we won't ask for a
    /// password") are told apart from the host being unreachable.
    private static func classify(_ stderr: String) -> SSHProbeResult {
        let lower = stderr.lowercased()
        let lastLine = stderr
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? localized("Connection failed")
        if lower.contains("permission denied")
            || lower.contains("too many authentication failures")
            || lower.contains("no supported authentication methods") {
            let methods = offeredMethods(stderr)
            if methods.contains("password") || methods.contains("keyboard-interactive") {
                return .wantsPassword(lastLine)
            }
            return .authFailed(lastLine)
        }
        if lower.contains("could not resolve") || lower.contains("name or service not known") {
            return .unreachable(localized("Host not found"))
        }
        if lower.contains("connection refused") { return .unreachable(localized("Connection refused")) }
        if lower.contains("no route to host") { return .unreachable(localized("No route to host")) }
        if lower.contains("timed out") { return .unreachable(localized("Timed out")) }
        return .unreachable(lastLine)
    }

    /// The authentication methods the *server* offered, read out of ssh's
    /// `Permission denied (publickey,password)` line. The parenthesised list is
    /// the far side's own answer to what it would have accepted, which is the
    /// only trustworthy way to tell "this box wants a password we refused to
    /// send" from "this box doesn't know our key". Lowercased; empty when the
    /// line carries no list (some servers and older ssh versions omit it).
    static func offeredMethods(_ stderr: String) -> [String] {
        guard let opening = stderr.range(of: "permission denied (", options: .caseInsensitive),
              let closing = stderr[opening.upperBound...].firstIndex(of: ")")
        else { return [] }
        return stderr[opening.upperBound..<closing]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    /// Whether a value cannot be written into a `Host` block faithfully: a line
    /// break (which would end the directive and start a new one) or any other
    /// control character. `ssh_config` has no escape for either.
    static func isUnwritable(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .control
        }
    }

    /// A destination as people write it — `[user@]host[:port]` — split into the
    /// three fields a `Host` block keeps apart. One Address field can then absorb
    /// a pasted `root@10.0.0.4:2222` instead of asking for it in pieces.
    ///
    /// A colon only means a port when it cannot mean an address. `[2001:db8::1]:22`
    /// splits on the bracket, and the brackets come off because `HostName` wants the
    /// literal bare. An unbracketed address with more than one colon is an IPv6
    /// literal in full — `2001:db8::1` has to stay one host, not become `2001:db8:`
    /// on port 1, which is both wrong and reachable.
    static func parseDestination(_ text: String) -> (user: String, host: String, port: String) {
        var rest = text.trimmingCharacters(in: .whitespaces)
        var user = ""
        // Last `@`, not the first: a username may legally contain one.
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[rest.startIndex..<at])
            rest = String(rest[rest.index(after: at)...])
        }
        func portValue(_ candidate: String) -> String? {
            !candidate.isEmpty && candidate.allSatisfy(\.isNumber) ? candidate : nil
        }
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            let inside = String(rest[rest.index(after: rest.startIndex)..<close])
            let trailing = String(rest[rest.index(after: close)...])
            let port = trailing.hasPrefix(":")
                ? portValue(String(trailing.dropFirst())) ?? "" : ""
            return (user, inside, port)
        }
        if rest.filter({ $0 == ":" }).count == 1, let colon = rest.lastIndex(of: ":"),
           let port = portValue(String(rest[rest.index(after: colon)...])) {
            return (user, String(rest[rest.startIndex..<colon]), port)
        }
        return (user, rest, "")
    }

    /// The name to give a host at `hostName`: its first label, since that is what
    /// people call the box (`build.example.com` is "build"), kept unique against
    /// the names already taken the way the Finder keeps a duplicate unique.
    ///
    /// An address that is all digits and dots is an IP, whose first label names
    /// nothing — the whole address is the only sensible name for it.
    static func suggestedAlias(forHost hostName: String, avoiding taken: Set<String>) -> String {
        guard let first = hostName.split(separator: ".").first.map(String.init), !first.isEmpty
        else { return "" }
        let base = hostName.allSatisfy { $0.isNumber || $0 == "." } ? hostName : first
        guard taken.contains(base) else { return base }
        // Bounded by the number of names that exist: with `taken.count` aliases in
        // play one of the first `taken.count + 2` suffixes must be free, so this
        // always returns a name — a fixed ceiling handed back the taken base and
        // let the sheet reject its own suggestion.
        for suffix in 2...(taken.count + 2) where !taken.contains("\(base)-\(suffix)") {
            return "\(base)-\(suffix)"
        }
        return base
    }

    /// The `User`/`IdentityFile` pairs already in use, most-used first (ties broken
    /// by config order). Offered by Add Host so the common case — every box signed
    /// into as the same user with the same key — is pre-filled rather than retyped.
    /// A pair that sets neither is dropped: it says nothing the defaults don't.
    static func suggestedIdentities(in hosts: [SSHConfigHost]) -> [SSHIdentity] {
        var counts: [SSHIdentity: Int] = [:]
        var order: [SSHIdentity: Int] = [:]
        for (index, host) in hosts.enumerated() {
            let identity = SSHIdentity(user: host.user, identityFile: host.identityFile)
            if identity.user.isEmpty && identity.identityFile == nil { continue }
            counts[identity, default: 0] += 1
            if order[identity] == nil { order[identity] = index }
        }
        let ranked: [(identity: SSHIdentity, count: Int, order: Int)] = counts.map {
            (identity: $0.key, count: $0.value, order: order[$0.key] ?? 0)
        }
        return ranked
            .sorted { $0.count == $1.count ? $0.order < $1.order : $0.count > $1.count }
            .map(\.identity)
    }

    /// The public key `ssh-copy-id` should install on `host`.
    ///
    /// A block that pins an `IdentityFile` gets that key's `.pub` sibling and
    /// nothing else: ssh will offer exactly the pinned key, so installing a
    /// different one would leave the host failing for the same reason with a new
    /// key on it.
    ///
    /// When the block pins nothing, the choice is narrower than "the best key on
    /// disk": ssh with no `IdentityFile` offers only the agent's keys and the
    /// default names below, so installing `work_security_key.pub` would report
    /// success and change nothing — the next connection never offers it. Only a
    /// key ssh would reach for on its own can be installed without also editing
    /// the host block, so anything else returns nil and the caller says so.
    static func publicKeyToInstall(for host: SSHConfigHost, keys: [SSHPublicKey]) -> SSHPublicKey? {
        if let identityFile = host.identityFile {
            let expanded = (identityFile as NSString).expandingTildeInPath
            let publicPath = expanded.hasSuffix(".pub") ? expanded : expanded + ".pub"
            return keys.first { $0.url.standardizedFileURL.path == publicPath }
        }
        // ssh_config(5)'s default IdentityFile list, strongest first.
        let defaultNames = [
            "id_ed25519_sk", "id_ed25519", "id_ecdsa_sk", "id_ecdsa", "id_rsa", "id_dsa",
        ]
        let offered = keys.filter {
            defaultNames.contains($0.name.replacingOccurrences(of: ".pub", with: ""))
        }
        return offered.min {
            let rank: (SSHPublicKey) -> Int = { key in
                defaultNames.firstIndex(of: key.name.replacingOccurrences(of: ".pub", with: ""))
                    ?? defaultNames.count
            }
            return rank($0) < rank($1)
        }
    }
}
