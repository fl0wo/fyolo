import AppKit
import SwiftUI

// MARK: - Connector

/// Connecting to GitHub, every way there is: the browser sign-in (github.com,
/// through fyolo's OAuth app), the GitHub CLI's existing sign-in, or a pasted
/// personal access token for any host — the path for GitHub Enterprise Server,
/// for organizations that block OAuth apps, and for anyone who already has a
/// token. Each ends the same way: the connection is verified and stored, and
/// `GitHubIssueAuth.connectionDidChange` tells every surface — this one included —
/// to reload.
@MainActor
final class GitHubConnector: ObservableObject {
    enum State: Equatable {
        case idle
        /// The browser sign-in is waiting for the user to enter this code.
        case awaitingApproval(userCode: String)
        /// A token is being checked against its server.
        case verifying
    }

    enum ConnectError: LocalizedError {
        case rejected
        case unreachable(host: String)
        case notGitHub(host: String)
        case invalidHost
        case emptyToken
        case cliUnavailable

        var errorDescription: String? {
            switch self {
            case .rejected:
                return localized("GitHub rejected this token. Check that it was copied whole and hasn’t expired.")
            case .unreachable(let host):
                return localized("Couldn’t reach \(host).")
            case .notGitHub(let host):
                return localized("\(host) doesn’t answer like a GitHub server.")
            case .invalidHost:
                return localized("Enter a host like github.com or github.example.com.")
            case .emptyToken:
                return localized("Paste a token first.")
            case .cliUnavailable:
                return localized("The GitHub CLI didn’t hand over a token. Run gh auth login in a terminal, then try again.")
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var errorMessage: String?
    /// The GitHub CLI's signed-in account, offered as a one-click way in.
    let cliAccount = GitHubCLI.signedInAccount()

    private var attempt: Task<Void, Never>?

    func connectInBrowser() {
        run {
            try await GitHubIssueAuth.connectInBrowser { self.state = .awaitingApproval(userCode: $0) }
        }
    }

    func connect(token rawToken: String, host rawHost: String) {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        run {
            guard !token.isEmpty else { throw ConnectError.emptyToken }
            guard let host = GitHubConnection.normalizedHost(rawHost) else { throw ConnectError.invalidHost }
            self.state = .verifying
            return try await Self.verified(GitHubConnection(host: host, token: token, source: .token))
        }
    }

    func connectWithCLI() {
        guard let account = cliAccount else { return }
        run {
            self.state = .verifying
            guard let token = await GitHubCLI.token(for: account.host) else {
                throw ConnectError.cliUnavailable
            }
            return try await Self.verified(
                GitHubConnection(host: account.host, token: token, source: .cli))
        }
    }

    /// Abandons whatever is in flight — a code nobody is going to enter, or a
    /// server that is taking too long to answer.
    func cancel() {
        attempt?.cancel()
        attempt = nil
        state = .idle
    }

    func clearError() {
        errorMessage = nil
    }

    private func run(_ connect: @escaping () async throws -> GitHubConnection) {
        attempt?.cancel()
        errorMessage = nil
        attempt = Task {
            do {
                let connection = try await connect()
                try Task.checkCancellation()
                state = .idle
                GitHubIssueAuth.store(connection)
            } catch {
                // A cancelled attempt was already put back to idle by `cancel()`,
                // and the error it unwinds with is not the user's to read.
                guard !Task.isCancelled else { return }
                state = .idle
                errorMessage = error.localizedDescription
            }
        }
    }

    /// One `GET /user` against the connection's own server: a pasted token and a
    /// typed host are only worth storing once that answers. The browser sign-in
    /// skips this — GitHub minted that token a moment ago.
    private static func verified(_ connection: GitHubConnection) async throws -> GitHubConnection {
        do {
            _ = try await GitHubIssueProvider(connection: connection).account()
            return connection
        } catch GitHubIssueProvider.APIError.status(401) {
            throw ConnectError.rejected
        } catch GitHubIssueProvider.APIError.status(404), GitHubIssueProvider.APIError.decoding {
            throw ConnectError.notGitHub(host: connection.host)
        } catch is URLError {
            throw ConnectError.unreachable(host: connection.host)
        }
    }
}

// MARK: - Connect view

/// The GitHub connect zero state, shared by every surface that needs an account.
/// The browser sign-in leads; the GitHub CLI's account follows when there is one;
/// a personal access token is always one click away — so someone who already has
/// a token, or whose organization or Enterprise server rules OAuth apps out, never
/// has to go through a sign-in that can't work for them.
struct GitHubConnectView: View {
    @ObservedObject var connector: GitHubConnector
    /// What connecting is *for* on the surface showing it.
    let title: String
    let message: String
    /// An error the host surface raised (a revoked token, say), shown until the
    /// connector has one of its own.
    var hostError: String?

    @State private var isEnteringToken = false
    @State private var token = ""
    @State private var host = GitHubConnection.dotComHost

    private let fieldWidth: CGFloat = 240

    var body: some View {
        switch connector.state {
        case .awaitingApproval(let userCode):
            GitHubPrompt(
                title: localized("Enter Code on GitHub"),
                message: localized("Type this code at github.com/login/device to approve Fyolo. Waiting for approval…"),
                errorMessage: connector.errorMessage
            ) {
                Text(userCode)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                ProgressView().controlSize(.small)
                Button(localized("Cancel")) { connector.cancel() }
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
        case .verifying:
            GitHubPrompt(
                title: localized("Connecting…"),
                message: localized("Checking the token with GitHub."),
                errorMessage: nil
            ) {
                ProgressView().controlSize(.small)
                Button(localized("Cancel")) { connector.cancel() }
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
        case .idle:
            if isEnteringToken { tokenForm } else { choices }
        }
    }

    private var choices: some View {
        GitHubPrompt(title: title, message: message, errorMessage: connector.errorMessage ?? hostError) {
            Button(localized("Connect GitHub")) { connector.connectInBrowser() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            if let account = connector.cliAccount {
                Button(localized("Use \(cliLabel(account)) from GitHub CLI")) { connector.connectWithCLI() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Button(localized("Use a Personal Access Token…")) {
                connector.clearError()
                isEnteringToken = true
            }
            .buttonStyle(.link)
            .controlSize(.small)
        }
    }

    private var tokenForm: some View {
        GitHubPrompt(
            title: localized("Personal Access Token"),
            message: localized("Paste a token with the repo scope. For GitHub Enterprise Server, change the host to yours."),
            errorMessage: connector.errorMessage
        ) {
            VStack(spacing: 8) {
                // Not localized: token prefixes read the same in every language.
                SecureField("ghp_… / github_pat_…", text: $token)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit(submit)
                    .capsuleField()
                HStack(spacing: 6) {
                    Text(localized("Host"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField(GitHubConnection.dotComHost, text: $host)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onSubmit(submit)
                }
                .capsuleField()
                HStack {
                    Button(localized("Cancel")) {
                        connector.clearError()
                        isEnteringToken = false
                        token = ""
                    }
                    .controlSize(.regular)
                    Button(localized("Connect"), action: submit)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let url = GitHubConnection.newTokenURL(
                    host: GitHubConnection.normalizedHost(host) ?? GitHubConnection.dotComHost) {
                    Button(localized("Create a Token…")) { NSWorkspace.shared.open(url) }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            }
            .frame(width: fieldWidth)
        }
    }

    private func submit() {
        connector.connect(token: token, host: host)
    }

    /// The CLI account as the button names it: just the login on github.com, with
    /// the host alongside when it is an Enterprise server.
    private func cliLabel(_ account: GitHubCLIAccount) -> String {
        account.host == GitHubConnection.dotComHost ? account.user : "\(account.user)@\(account.host)"
    }
}

/// The GitHub zero-state block — mark, title, one line of explanation, the
/// actions, and any error beneath them. Shared by every surface that talks to
/// GitHub (the Issues pane, the welcome page), so a prompt reads the same
/// wherever the user meets it.
struct GitHubPrompt<Actions: View>: View {
    let title: String
    let message: String
    let errorMessage: String?
    private let actions: Actions

    init(
        title: String, message: String, errorMessage: String?,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.message = message
        self.errorMessage = errorMessage
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 10) {
            HugeIconView(icon: .github, size: 34, color: .secondary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            actions
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }
        }
    }
}
