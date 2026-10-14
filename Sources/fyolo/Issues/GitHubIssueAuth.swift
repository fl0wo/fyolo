import AppKit
import Security

// MARK: - GitHub connection

/// How fyolo reaches GitHub: which server, with which credential, and how the
/// credential was obtained. One of these lives in the Keychain; every GitHub
/// surface (the Issues pane, the welcome page's clone list, a local clone)
/// reads it rather than a bare token, so a GitHub Enterprise Server connection
/// works everywhere a github.com one does.
struct GitHubConnection: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        /// The OAuth device flow — github.com only, since it needs fyolo's app.
        case browser
        /// A personal access token the user pasted.
        case token
        /// The token the GitHub CLI (`gh`) already holds.
        case cli
    }

    static let dotComHost = "github.com"

    /// Lowercased host with no scheme, path, or port: `github.com`,
    /// `github.example.com`, `octocorp.ghe.com`.
    let host: String
    let token: String
    let source: Source

    var isDotCom: Bool { host == Self.dotComHost }

    /// The REST root. github.com and GHE.com's data-residency hosts serve it from
    /// an `api.` subdomain; GitHub Enterprise Server serves it under `/api/v3`.
    var apiBase: String {
        if isDotCom { return "https://api.github.com" }
        if host.hasSuffix(".ghe.com") { return "https://api.\(host)" }
        return "https://\(host)/api/v3"
    }

    /// The GraphQL endpoint, which sits beside the REST root rather than under it
    /// on GitHub Enterprise Server.
    var graphQLURL: URL? {
        if isDotCom { return URL(string: "https://api.github.com/graphql") }
        if host.hasSuffix(".ghe.com") { return URL(string: "https://api.\(host)/graphql") }
        return URL(string: "https://\(host)/api/graphql")
    }

    /// Where the user changes what this credential can reach — the place a 403 on
    /// an organization's private repository gets fixed. For the browser sign-in
    /// that is the OAuth app's grant page; for a token, the token list, where
    /// single sign-on is authorized per token.
    var accessSettingsURL: URL? {
        switch source {
        case .browser:
            URL(string: "https://github.com/settings/connections/applications/\(GitHubIssueAuth.clientID)")
        case .token, .cli:
            URL(string: "https://\(host)/settings/tokens")
        }
    }

    /// A new classic token on `host`, pre-filled with the `repo` scope and a name
    /// the user will recognize later in their token list. Classic rather than
    /// fine-grained because one classic token reaches every organization the user
    /// belongs to; a fine-grained one is bound to a single owner, and the clone
    /// list would silently show only part of the user's repositories.
    static func newTokenURL(host: String) -> URL? {
        URL(string: "https://\(host)/settings/tokens/new?scopes=repo&description=Fyolo")
    }

    /// What the user typed in the Host field, reduced to a bare host — or `nil`
    /// when nothing usable is left. Accepts a pasted URL (`https://ghe.corp/`) and
    /// folds github.com's aliases into it, so `www.github.com` or `api.github.com`
    /// doesn't become a "GitHub Enterprise" connection with the wrong API root.
    static func normalizedHost(_ input: String) -> String? {
        var host = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where host.hasPrefix(scheme) {
            host.removeFirst(scheme.count)
        }
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        while host.hasSuffix(".") { host.removeLast() }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard !host.isEmpty, host.contains("."),
              host.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else { return nil }
        if host == "www.github.com" || host == "api.github.com" { return dotComHost }
        return host
    }

    /// Reads a Keychain payload. Installs from before Enterprise support stored
    /// the bare device-flow token, so anything that isn't a JSON connection is
    /// taken as exactly that — a github.com browser sign-in — rather than
    /// signing the user out.
    static func decode(_ data: Data) -> GitHubConnection? {
        if let connection = try? JSONDecoder().decode(GitHubConnection.self, from: data) {
            return connection
        }
        guard let token = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty, !token.hasPrefix("{")
        else { return nil }
        return GitHubConnection(host: dotComHost, token: token, source: .browser)
    }
}

/// The stored GitHub connection and the OAuth Device Flow that makes one. Device
/// Flow is the one OAuth shape an open-source app can ship — it needs only this
/// public client id, no secret and no callback server. The token asks for `repo`
/// scope so the write milestone (issue #100) won't need a re-auth.
enum GitHubIssueAuth {
    /// The fyolo OAuth App's public client id (owned by the fyolo-sh org,
    /// "Enable Device Flow" checked). Public by design — device flow needs no
    /// secret. Overridable via the environment for testing against another app.
    static var clientID: String {
        ProcessInfo.processInfo.environment["FYOLO_GITHUB_CLIENT_ID"]
            ?? "Ov23lik1VrZvkHndjlJ8"
    }

    /// Posted on the main thread whenever the stored connection is replaced or
    /// removed. Every GitHub surface — the Issues pane, the welcome page, Settings,
    /// the issue cache — reloads from the Keychain on it, so connecting or
    /// disconnecting anywhere is seen everywhere, including by the surface that did it.
    static let connectionDidChange = Notification.Name("sh.fyolo.github.connectionDidChange")

    // MARK: Keychain

    /// Per channel, so the dev build can be taken back to "never connected" to
    /// exercise onboarding without signing the release app out of GitHub.
    private static let service = "sh.fyolo.app.issues" + AppChannel.suffix
    private static let account = "github"

    /// The stored connection, or `nil` when the user never connected (or disconnected).
    static func storedConnection() -> GitHubConnection? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return GitHubConnection.decode(data)
    }

    static func store(_ connection: GitHubConnection) {
        let data: Data
        do {
            data = try JSONEncoder().encode(connection)
        } catch {
            Log.issues.error("encoding the GitHub connection failed: \(error, privacy: .public)")
            return
        }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            Log.issues.error("keychain store failed: \(status)")
        }
        NotificationCenter.default.post(name: connectionDidChange, object: nil)
    }

    static func deleteConnection() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        NotificationCenter.default.post(name: connectionDidChange, object: nil)
    }

    // MARK: Device flow

    struct DeviceCode: Sendable {
        /// The 8-character code the user types at github.com/login/device.
        let userCode: String
        let verificationURL: URL
        /// Opaque code we poll the token endpoint with.
        fileprivate let deviceCode: String
        /// Server-mandated seconds between polls.
        fileprivate let interval: Int
        fileprivate let expiresAt: Date
    }

    enum DeviceFlowError: LocalizedError {
        case denied
        case expired
        case network(String)

        var errorDescription: String? {
            switch self {
            case .denied: return "The sign-in was declined on github.com."
            case .expired: return "The code expired before it was entered. Try connecting again."
            case .network(let message): return message
            }
        }
    }

    /// The whole browser sign-in: request a code, hand it to `showCode` for
    /// display, open the verification page, and wait for approval. github.com
    /// only — the device flow runs against fyolo's OAuth app, which a GitHub
    /// Enterprise Server has never heard of.
    @MainActor
    static func connectInBrowser(showCode: (String) -> Void) async throws -> GitHubConnection {
        let code = try await requestDeviceCode()
        showCode(code.userCode)
        NSWorkspace.shared.open(code.verificationURL)
        let token = try await waitForToken(code)
        return GitHubConnection(host: GitHubConnection.dotComHost, token: token, source: .browser)
    }

    /// Step 1: ask GitHub for a user code to show (and open the verification page).
    static func requestDeviceCode() async throws -> DeviceCode {
        let body = "client_id=\(clientID)&scope=repo"
        let json = try await postForm(
            url: URL(string: "https://github.com/login/device/code")!, body: body)
        guard let userCode = json["user_code"] as? String,
              let device = json["device_code"] as? String,
              let uri = json["verification_uri"] as? String,
              let url = URL(string: uri)
        else {
            let message = (json["error_description"] as? String) ?? "GitHub returned an unexpected reply."
            throw DeviceFlowError.network(message)
        }
        let interval = json["interval"] as? Int ?? 5
        let expiresIn = json["expires_in"] as? Int ?? 900
        return DeviceCode(
            userCode: userCode,
            verificationURL: url,
            deviceCode: device,
            interval: interval,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn))
        )
    }

    /// Step 2: poll until the user approves in the browser; returns the token.
    /// Honors GitHub's pacing (`interval`, `slow_down`) and gives up at expiry.
    static func waitForToken(_ code: DeviceCode) async throws -> String {
        var interval = max(code.interval, 5)
        let body = "client_id=\(clientID)&device_code=\(code.deviceCode)"
            + "&grant_type=urn:ietf:params:oauth:grant-type:device_code"
        while Date() < code.expiresAt {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            let json = try await postForm(
                url: URL(string: "https://github.com/login/oauth/access_token")!, body: body)
            if let token = json["access_token"] as? String { return token }
            switch json["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "access_denied": throw DeviceFlowError.denied
            case "expired_token": throw DeviceFlowError.expired
            default:
                let message = (json["error_description"] as? String) ?? "GitHub returned an unexpected reply."
                throw DeviceFlowError.network(message)
            }
        }
        throw DeviceFlowError.expired
    }

    private static func postForm(url: URL, body: String) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        } catch let error as DeviceFlowError {
            throw error
        } catch {
            throw DeviceFlowError.network(error.localizedDescription)
        }
    }
}

// MARK: - GitHub CLI

/// An account the GitHub CLI (`gh`) is signed in to on this Mac.
struct GitHubCLIAccount: Equatable, Sendable {
    let host: String
    let user: String
}

/// Borrows the GitHub CLI's sign-in, so a developer who has run `gh auth login`
/// connects in one click without minting anything new. fyolo never runs a login
/// flow of its own here — only a credential the user's own tools already hold.
enum GitHubCLI {
    /// Where `gh` installs: Homebrew on Apple silicon and Intel, MacPorts, and the
    /// official package. A GUI app inherits launchd's bare `PATH`, so searching
    /// `PATH` would miss every one of them.
    private static let executableCandidates = [
        "/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/opt/local/bin/gh",
    ]

    private static var executable: String? {
        executableCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `gh`'s config directory, resolved the way `gh` resolves it.
    private static var hostsFile: URL {
        let environment = ProcessInfo.processInfo.environment
        if let directory = environment["GH_CONFIG_DIR"], !directory.isEmpty {
            return URL(fileURLWithPath: directory).appendingPathComponent("hosts.yml")
        }
        let config = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return config.appendingPathComponent("gh/hosts.yml")
    }

    /// The account worth offering — github.com's when there is one — or `nil` when
    /// `gh` isn't installed or isn't signed in. Reads only the hosts file, which
    /// holds no secret on a modern `gh` (the token is in its Keychain item), so it
    /// is cheap enough to ask every time a connect prompt appears.
    static func signedInAccount() -> GitHubCLIAccount? {
        guard executable != nil,
              let text = try? String(contentsOf: hostsFile, encoding: .utf8)
        else { return nil }
        let accounts = accounts(inHostsFile: text)
        return accounts.first { $0.host == GitHubConnection.dotComHost } ?? accounts.first
    }

    /// The accounts in a `hosts.yml`: each top-level key is a host, and its
    /// `user:` line names the active account. Pure, so the shape `gh` writes can be
    /// pinned down in tests; a host with no `user:` is skipped, since `gh` writes
    /// one for every completed login.
    static func accounts(inHostsFile text: String) -> [GitHubCLIAccount] {
        var accounts: [GitHubCLIAccount] = []
        var host: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.first?.isWhitespace == false {
                let key = line.trimmingCharacters(in: .whitespaces)
                host = key.hasSuffix(":")
                    ? GitHubConnection.normalizedHost(String(key.dropLast()))
                    : nil
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let current = host, trimmed.hasPrefix("user:") else { continue }
            let user = trimmed.dropFirst("user:".count).trimmingCharacters(in: .whitespaces)
            guard !user.isEmpty else { continue }
            accounts.append(GitHubCLIAccount(host: current, user: user))
            host = nil
        }
        return accounts
    }

    /// The token `gh` holds for `host`, from `gh auth token`, or `nil` when it
    /// can't hand one over.
    static func token(for host: String) async -> String? {
        guard let executable else { return nil }
        let output = await Task.detached(priority: .userInitiated) {
            FyoloStore.runProcess(executable, ["auth", "token", "--hostname", host])
        }.value
        guard let output, output.exitCode == 0 else {
            if let output {
                Log.issues.error("gh auth token failed: \(output.standardError, privacy: .public)")
            }
            return nil
        }
        let token = output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
