import Combine
import SwiftUI

/// App-and-account settings: language, the GitHub integration, and the
/// usage-statistics opt-out. What is left is what belongs to the install and the
/// person, rather than to a machine or to the agents.
///
/// It used to also carry the `fyolo` command-line tool, the session-control
/// skill and the status hooks. Every one of those installs a file **on a
/// machine** — an agent's config directory, `/usr/local/bin` — so presented here
/// they read as app-wide and silently meant this Mac, which is why a VPS agent
/// had no hook status and nobody could see why. They now live on a machine's pane
/// (RFC §D8).
///
/// Task-completion notifications left too, to Settings ▸ Agents. A banner fires
/// because a *hook* fired, and the hook's switch was on another tab — so the two
/// halves of one feature sat where neither could say it depended on the other,
/// and a user who turned the banner on with the hooks off got a switch that did
/// nothing and no way to find out why.
struct GeneralSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                LanguageRow()
            } header: {
                SectionHeaderLabel(title: localized("Language"))
            }
            Section {
                Toggle(isOn: $settings.githubIntegrationEnabled) {
                    SettingsLabel(
                        title: localized("GitHub"),
                        subtext: localized("Shows the Issues pane in the inspector for projects whose remote is on GitHub."),
                        titleFont: .headline
                    )
                }
                .toggleStyle(.switch)
                if settings.githubIntegrationEnabled {
                    GitHubAccountRow()
                }
                Toggle(isOn: $settings.gitToolbarControls) {
                    SettingsLabel(
                        title: localized("Git status"),
                        subtext: localized("Counts uncommitted files beside the branch name, offers to pull when the remote is ahead, and adds an Inspect tab to the git pane."),
                        titleFont: .headline
                    )
                }
                .toggleStyle(.switch)
            } header: {
                SectionHeaderLabel(title: localized("Integrations"))
            }
            Section {
                Toggle(isOn: $settings.analyticsEnabled) {
                    SettingsLabel(
                        title: localized("Usage statistics"),
                        subtext: localized("Sends one anonymous event a day so the project can count active installs. No project paths, no terminal contents, no account."),
                        titleFont: .headline
                    )
                }
                .toggleStyle(.switch)
            } header: {
                SectionHeaderLabel(title: localized("Privacy"))
            }
        }
        .formStyle(.grouped)
    }
}

/// The connected GitHub account, read back from the Keychain and kept in step
/// with it: connecting or disconnecting anywhere — here, the welcome page, the
/// Issues pane — lands here too.
@MainActor
final class GitHubAccountModel: ObservableObject {
    @Published private(set) var connection: GitHubConnection?
    /// The connection's login, once GitHub has confirmed it; `nil` while asking,
    /// or when the token no longer works.
    @Published private(set) var login: String?
    @Published private(set) var isTokenRejected = false
    let connector = GitHubConnector()
    private var connectionObserver: AnyCancellable?

    init() {
        connectionObserver = NotificationCenter.default
            .publisher(for: GitHubIssueAuth.connectionDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
    }

    func reload() {
        Task { await refresh() }
    }

    func refresh() async {
        let stored = GitHubIssueAuth.storedConnection()
        connection = stored
        login = nil
        isTokenRejected = false
        guard let stored else { return }
        do {
            login = try await GitHubIssueProvider(connection: stored).account()
        } catch GitHubIssueProvider.APIError.status(401) {
            isTokenRejected = true
        } catch {
            Log.issues.error("reading the GitHub account failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func disconnect() {
        GitHubIssueAuth.deleteConnection()
    }
}

/// Settings' GitHub account row: who fyolo is signed in as, on which server and
/// how, with Disconnect — or, when nothing is connected, the same connect choices
/// the welcome page and the Issues pane offer, token and Enterprise host included.
private struct GitHubAccountRow: View {
    @StateObject private var model = GitHubAccountModel()

    var body: some View {
        Group {
            if let connection = model.connection {
                HStack(alignment: .center) {
                    SettingsLabel(
                        title: accountTitle(connection),
                        subtext: detail(connection)
                    )
                    Spacer()
                    Button(localized("Disconnect")) { model.disconnect() }
                }
            } else {
                GitHubConnectView(
                    connector: model.connector,
                    title: localized("GitHub Account"),
                    message: localized("Connect to read issues and pull requests, and to clone your repositories.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }
        .task { await model.refresh() }
    }

    private func accountTitle(_ connection: GitHubConnection) -> String {
        if let login = model.login { return "@\(login)" }
        return model.isTokenRejected ? localized("Token no longer accepted") : connection.host
    }

    private func detail(_ connection: GitHubConnection) -> String {
        let via: String
        switch connection.source {
        case .browser: via = localized("Connected through the browser")
        case .cli: via = localized("Connected through the GitHub CLI")
        case .token: via = localized("Connected with a personal access token")
        }
        return model.login == nil ? via : "\(connection.host) · \(via)"
    }
}
