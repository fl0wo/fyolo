import AppKit
import AuthenticationServices
import CryptoKit
import Security

// MARK: - Linear connection

/// The stored Linear credential: an OAuth token fyolo minted through the
/// browser sign-in, or a personal API key the user pasted. Lives in the
/// Keychain beside the GitHub connection.
struct LinearConnection: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        case oauth
        case apiKey
    }

    let accessToken: String
    /// Present on OAuth tokens. Linear rotates it on every refresh.
    let refreshToken: String?
    /// When the OAuth access token stops working — Linear issues them for 24 hours.
    let expiresAt: Date?
    let source: Source

    /// Linear reads an OAuth token as a bearer and a personal API key bare.
    var authorizationHeader: String {
        source == .oauth ? "Bearer \(accessToken)" : accessToken
    }

    /// Whether the access token is about to lapse, so the next request should
    /// renew it first rather than fail and retry.
    var isExpiring: Bool {
        guard source == .oauth, let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 120
    }
}

/// The stored Linear connection and the OAuth sign-in that makes one. The
/// sign-in is the authorization-code flow with PKCE: Linear makes the client
/// secret optional when a code verifier is sent, so — like GitHub's device flow
/// — it needs only this public client id, and the secret never ships.
enum LinearAuth {
    /// fyolo's Linear OAuth application. Public by design; overridable to test
    /// against another application.
    static var clientID: String {
        ProcessInfo.processInfo.environment["FYOLO_LINEAR_CLIENT_ID"]
            ?? "9581bc605996959c7d41c1f903b81d38"
    }

    /// Registered on the OAuth application. `ASWebAuthenticationSession` catches
    /// the redirect itself, so it never reaches Launch Services — one URL serves
    /// the release and dev apps alike.
    static let redirectURI = "fyolo://oauth/linear"
    private static let callbackScheme = "fyolo"

    /// Read only: agents write to Linear through its MCP server, never through fyolo.
    private static let scope = "read"

    /// Posted on the main thread when the connection is replaced or removed —
    /// not when a refresh renews the token, which changes nothing anyone shows.
    static let connectionDidChange = Notification.Name("sh.fyolo.linear.connectionDidChange")

    /// Where a personal API key is made.
    static let apiKeySettingsURL = URL(string: "https://linear.app/settings/account/security")

    // MARK: Keychain

    private static let service = "sh.fyolo.app.issues" + AppChannel.suffix
    private static let account = "linear"

    static func storedConnection() -> LinearConnection? {
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
        do {
            return try JSONDecoder().decode(LinearConnection.self, from: data)
        } catch {
            Log.issues.error("decoding the Linear connection failed: \(error, privacy: .public)")
            return nil
        }
    }

    /// `announce` is false for a refresh: the same account with a new token
    /// must not send every pane back through its connect ladder.
    static func store(_ connection: LinearConnection, announce: Bool = true) {
        let data: Data
        do {
            data = try JSONEncoder().encode(connection)
        } catch {
            Log.issues.error("encoding the Linear connection failed: \(error, privacy: .public)")
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
            Log.issues.error("keychain store failed for Linear: \(status)")
        }
        if announce { announceChange() }
    }

    /// Forgets the connection, and for an OAuth token also revokes it, so a
    /// disconnect leaves no live grant behind in the user's Linear settings.
    static func disconnect() {
        let revoked = storedConnection()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        announceChange()
        if let revoked, revoked.source == .oauth {
            Task.detached { await revoke(revoked) }
        }
    }

    private static func announceChange() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: connectionDidChange, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: connectionDidChange, object: nil)
            }
        }
    }

    // MARK: Sign-in

    enum SignInError: LocalizedError {
        case cancelled
        case couldNotStart
        case stateMismatch
        case denied(String)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return nil
            case .couldNotStart: return localized("Couldn’t open the Linear sign-in.")
            case .stateMismatch: return localized("The sign-in reply didn’t match this request. Try again.")
            case .denied(let message), .network(let message): return message
            }
        }
    }

    /// The whole browser sign-in: open Linear's consent page in an
    /// authentication sheet, take the code from the redirect, and trade it and
    /// the verifier for a token.
    @MainActor
    static func connectInBrowser() async throws -> LinearConnection {
        let verifier = randomURLSafeString(byteCount: 48)
        let state = randomURLSafeString(byteCount: 16)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded

        var components = URLComponents(string: "https://linear.app/oauth/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let authorizeURL = components?.url else { throw SignInError.couldNotStart }

        let callback = try await LinearWebAuthenticator().authenticate(
            url: authorizeURL, callbackScheme: callbackScheme)
        let reply = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { reply.first { $0.name == name }?.value }

        if let error = value("error") {
            throw SignInError.denied(value("error_description") ?? localized("Linear declined the sign-in (\(error))."))
        }
        guard value("state") == state else { throw SignInError.stateMismatch }
        guard let code = value("code") else {
            throw SignInError.network(localized("Linear returned an unexpected reply."))
        }
        return try await requestToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
    }

    /// A renewed OAuth token. With PKCE, Linear needs only the client id beside
    /// the refresh token.
    static func refreshed(_ connection: LinearConnection) async throws -> LinearConnection {
        guard connection.source == .oauth, let refreshToken = connection.refreshToken else {
            throw LinearAPIError.unauthorized
        }
        do {
            return try await requestToken([
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": clientID,
            ])
        } catch SignInError.denied {
            throw LinearAPIError.unauthorized
        }
    }

    private static func requestToken(_ fields: [String: String]) async throws -> LinearConnection {
        struct TokenReply: Decodable {
            let accessToken: String?
            let refreshToken: String?
            let expiresIn: Double?
            let error: String?
            let errorDescription: String?
        }
        guard let url = URL(string: "https://api.linear.app/oauth/token") else {
            throw SignInError.couldNotStart
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = Data(formEncoded(fields).utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw SignInError.network(error.localizedDescription)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let reply: TokenReply
        do {
            reply = try decoder.decode(TokenReply.self, from: data)
        } catch {
            throw SignInError.network(localized("Linear returned an unexpected reply."))
        }
        guard let token = reply.accessToken else {
            let message = reply.errorDescription ?? reply.error ?? localized("Linear returned an unexpected reply.")
            if reply.error == "invalid_grant" { throw SignInError.denied(message) }
            throw SignInError.network(message)
        }
        return LinearConnection(
            accessToken: token,
            refreshToken: reply.refreshToken,
            expiresAt: reply.expiresIn.map { Date().addingTimeInterval($0) },
            source: .oauth
        )
    }

    private static func revoke(_ connection: LinearConnection) async {
        guard let url = URL(string: "https://api.linear.app/oauth/revoke") else { return }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = Data(formEncoded(["token": connection.accessToken]).utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                Log.issues.info("Linear token revoke answered \(http.statusCode)")
            }
        } catch {
            Log.issues.error("Linear token revoke failed: \(error, privacy: .public)")
        }
    }

    private static func formEncoded(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }.map { key, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(encoded)"
        }.joined(separator: "&")
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        if SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) != errSecSuccess {
            // Never expected; the system generator is still a sound fallback.
            var generator = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return Data(bytes).base64URLEncoded
    }
}

private extension Data {
    /// Base64 with the URL-safe alphabet and no padding — RFC 7636's encoding
    /// for the verifier and challenge.
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Token renewal

/// Hands every Linear request a token that works, renewing an expiring OAuth
/// token at most once at a time. Linear rotates the refresh token on each use,
/// so two panes refreshing at once would race each other into a revoked grant.
actor LinearTokenRenewer {
    static let shared = LinearTokenRenewer()

    private var renewal: Task<LinearConnection, Error>?

    /// The connection to send: `connection` itself while it is fresh, or a
    /// renewed one. `force` renews even a token that has not lapsed yet — the
    /// answer to a 401.
    func usable(_ connection: LinearConnection, force: Bool = false) async throws -> LinearConnection {
        // Another request may already have renewed past the token we were handed.
        let current = LinearAuth.storedConnection() ?? connection
        if current.accessToken != connection.accessToken, !current.isExpiring { return current }
        guard force || current.isExpiring else { return current }
        guard current.source == .oauth else { throw LinearAPIError.unauthorized }
        if let renewal { return try await renewal.value }
        let task = Task { () throws -> LinearConnection in
            let renewed = try await LinearAuth.refreshed(current)
            LinearAuth.store(renewed, announce: false)
            return renewed
        }
        renewal = task
        defer { renewal = nil }
        return try await task.value
    }
}

// MARK: - Authentication sheet

/// Runs one `ASWebAuthenticationSession` and keeps it alive until it answers.
/// The session shares the user's browser cookies, so someone already signed in
/// to Linear only has to approve.
@MainActor
private final class LinearWebAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    /// Chosen on the main actor before the session starts, because the system
    /// may ask for it from any thread.
    nonisolated(unsafe) private var anchor: ASPresentationAnchor?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            // `@Sendable` keeps the handler off the main actor: written inside this
            // main-actor method it would otherwise inherit that isolation, and Swift
            // checks it on entry — a trap, since AuthenticationServices calls back on
            // its own XPC queue. The hop to the main actor happens inside instead.
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { @Sendable callback, error in
                Task { @MainActor in self.complete(callback: callback, error: error) }
            }
            anchor = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                finish(.failure(LinearAuth.SignInError.couldNotStart))
            }
        }
    }

    private func complete(callback: URL?, error: Error?) {
        if let callback {
            finish(.success(callback))
        } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
            finish(.failure(LinearAuth.SignInError.cancelled))
        } else {
            finish(.failure(LinearAuth.SignInError.network(
                error?.localizedDescription ?? localized("The Linear sign-in failed."))))
        }
    }

    /// Resumes once: a session that failed to start never calls its handler,
    /// but one that did must not be answered twice.
    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        session = nil
        continuation.resume(with: result)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }
}
