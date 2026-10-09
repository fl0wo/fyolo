import Foundation
import Security

/// A password for an SSH host, kept in the login Keychain and handed to the
/// system `ssh` through the one channel OpenSSH itself provides for it.
///
/// **Why this shape.** ssh_config has no directive that holds a password, and
/// fyolo never links an SSH library, so the password cannot travel with the
/// host block or through a client we control. What OpenSSH does offer is
/// `SSH_ASKPASS`: a program it runs when it needs a secret, reading the answer
/// off that program's stdout. `SSH_ASKPASS_REQUIRE=force` (OpenSSH 8.4+) makes it
/// use that program even when a terminal is present, which is what lets a session
/// with a real PTY skip the prompt.
///
/// **Where the secret is, and is not.** It is in the Keychain and nowhere else.
/// The askpass helper is a two-line script that asks `security(1)` for it at the
/// moment ssh asks, so the password is never in an argument list (`sshpass`'s
/// flaw — argv is world-readable through `ps`), never in the environment, and
/// never written to a file. fyolo itself doesn't read it back; only the helper
/// does, and only when ssh runs it.
///
/// **The trust boundary, stated plainly.** Writing through `security(1)` leaves an
/// item whose access list trusts `security(1)`, so any process running as this
/// user can read it back without a prompt. That is the same standing any process
/// has over an `ssh-add --apple-use-keychain` passphrase, and it is the cost of
/// letting the system ssh binary — rather than an embedded client — do the
/// authenticating. A password is offered here because the user asked for one; a
/// key remains the better credential and the only one the daemon paths can use
/// without giving up `BatchMode`.
enum SSHPasswordStore {
    /// Per-channel, so a dev build's saved passwords are as separate from the
    /// release app's as every other piece of its state.
    static var service: String { "sh.fyolo.ssh" + AppChannel.suffix }

    /// Stores `password` for a `~/.ssh/config` alias, replacing any previous one.
    ///
    /// `-w` with no value makes `security` read the password from stdin, asked for
    /// twice the way an interactive prompt would. That detour exists to keep the
    /// value out of the argument list.
    static func save(_ password: String, for alias: String) throws {
        // A newline can't survive either leg of the trip: `security` reads the
        // confirmation line-wise, and ssh takes only the helper's first line. Left
        // unchecked it stores a silently truncated password whose failure looks
        // like a wrong one.
        guard !password.contains(where: \.isNewline) else {
            throw SSHPasswordError.passwordContainsNewline
        }
        let status = run([
            "add-generic-password", "-U",
            "-s", service, "-a", alias,
            "-l", "fyolo: \(alias)",
            "-D", "SSH password",
            "-j", "Used by Fyolo to sign in to \(alias). Delete this to make Fyolo ask again.",
            "-w",
        ], stdin: Data("\(password)\n\(password)\n".utf8))
        guard status == 0 else { throw SSHPasswordError.keychainWriteFailed }
    }

    @discardableResult
    static func remove(for alias: String) -> Bool {
        let status = run(["delete-generic-password", "-s", service, "-a", alias])
        // 44 is "item not found", which is the state the caller asked for.
        return status == 0 || status == 44
    }

    /// Whether a password is stored for `alias`.
    ///
    /// Asked through `SecItemCopyMatching` rather than `security(1)` because this
    /// gates every SSH session launch and launches happen on the main actor: a
    /// subprocess there costs ~50 ms of frozen window per session, and a
    /// `securityd` having a bad day costs more than that. The query returns no
    /// data — only whether the item exists — so it neither unlocks the secret nor
    /// prompts. Writing still goes through `security(1)`, whose access list is
    /// what lets the askpass helper read the item back without a prompt.
    static func hasPassword(for alias: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: alias,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Runs `security` and returns its exit status, draining both pipes before the
    /// wait. A child blocked writing into a pipe nobody reads never exits, and the
    /// wait would then never return — the same deadlock `SSHConfigFile.testConnection`
    /// spells out. `security` is terse enough that it has not happened, which is
    /// exactly why it would happen on the one machine with a chatty keychain error.
    private static func run(_ arguments: [String], stdin: Data? = nil) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let input = Pipe()
        if stdin != nil { process.standardInput = input }
        do { try process.run() } catch { return -1 }
        if let stdin {
            input.fileHandleForWriting.write(stdin)
            input.fileHandleForWriting.closeFile()
        }
        // Read to EOF on both before waiting; EOF arrives when the child exits.
        _ = output.fileHandleForReading.readDataToEndOfFile()
        _ = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// The environment an `ssh` child needs to answer a password prompt for
    /// `alias` from the Keychain, or empty when nothing is stored for it — in
    /// which case ssh behaves exactly as it does today.
    ///
    /// `DISPLAY` is set because ssh's older askpass path checks it; `REQUIRE=force`
    /// makes that irrelevant on 8.4+, and setting both costs nothing. The value is
    /// deliberately not a real display: nothing ever connects to it.
    static func askpassEnvironment(for alias: String) -> [String: String] {
        guard hasPassword(for: alias), let helper = try? helperURL() else { return [:] }
        return [
            "SSH_ASKPASS": helper.path,
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": ":0",
            "FYOLO_SSH_SERVICE": service,
            "FYOLO_SSH_ALIAS": alias,
        ]
    }

    /// The askpass helper on disk, written on first use and rewritten whenever it
    /// drifts from the text below. It holds no secret — only the lookup — so it is
    /// safe to leave in the app's support directory between runs.
    ///
    /// `exec` rather than a subshell so ssh reads the password straight off
    /// `security`'s stdout with no shell sitting in between it and the pipe.
    static func helperURL() throws -> URL {
        let directory = AppChannel.supportDirectory
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appendingPathComponent("ssh-askpass")
        let script = """
            #!/bin/sh
            # Written by Fyolo. Answers ssh's password prompt from the login
            # Keychain; holds no secret itself.
            exec /usr/bin/security find-generic-password -w \
            -s "$FYOLO_SSH_SERVICE" -a "$FYOLO_SSH_ALIAS"

            """
        if (try? String(contentsOf: url, encoding: .utf8)) != script {
            try script.write(to: url, atomically: true, encoding: .utf8)
        }
        // Re-asserted every time: an atomic write lands a fresh file that inherits
        // the process umask, and ssh silently ignores an askpass it cannot execute.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: url.path
        )
        return url
    }
}

enum SSHPasswordError: Error, LocalizedError {
    case keychainWriteFailed
    case passwordContainsNewline

    var errorDescription: String? {
        switch self {
        case .keychainWriteFailed:
            return localized("Couldn’t save the password to your Keychain.")
        case .passwordContainsNewline:
            return localized("A password can’t contain a line break.")
        }
    }
}
