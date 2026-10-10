import AppKit
import Combine
import SwiftUI

/// The center-pane welcome, shown by `TerminalPane` whenever no session is mounted
/// — which includes the very first launch, since `Workspace.firstRun()` seeds no
/// session. It asks one question, "which project?", and offers the three answers
/// in the order someone reaches for them: a folder opened before (**Recent**, most
/// recent first, hidden when there is none), any other folder (**Open Folder…**),
/// or one of the user's GitHub repositories (**Clone from GitHub**, which offers
/// Connect first when no account is linked).
///
/// Everything here reuses existing entry points — `addProject`,
/// `presentOpenProjectPanel`, `cloneRepository`, and the `GitHubConnector` the
/// Issues pane uses — so the welcome adds no machinery, only a front door onto it.
struct WelcomeView: View {
    @EnvironmentObject var store: FyoloStore
    @EnvironmentObject var settings: AppSettings

    /// The whole page is one narrow, centered column — hero, then the three ways
    /// in — so it reads like Xcode's welcome window rather than a document spread
    /// across a wide pane.
    private let columnWidth: CGFloat = 400

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                hero
                openColumn
                if settings.githubIntegrationEnabled {
                    WelcomeRepositories()
                }
            }
            .frame(width: columnWidth)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
        }
        // A system scroller ignores the terminal theme the page sits on; the page
        // still scrolls when the window is short.
        .scrollIndicators(.hidden)
    }

    /// The hero: the real app icon, big and centered, with the wordmark and the
    /// page's one question stacked directly beneath.
    private var hero: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)
            VStack(spacing: 4) {
                Text("Fyolo")
                    .font(.system(size: 32, weight: .bold))
                Text(localized("Choose a project to start."))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Open

    private var openColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !recentEntries.isEmpty {
                WelcomeSectionLabel(text: localized("Recent"))
                ForEach(recentEntries) { entry in
                    WelcomeListRow(
                        icon: .folder,
                        title: entry.name,
                        subtitle: (entry.path as NSString).abbreviatingWithTildeInPath
                    ) {
                        store.addProject(at: URL(fileURLWithPath: entry.path))
                    }
                }
                Spacer().frame(height: 10)
            }
            WelcomeActionRow(
                icon: HugeIconView(icon: .folder, size: 16, color: .secondary),
                title: localized("Open Folder…"),
                shortcut: "⌘O"
            ) { store.presentOpenProjectPanel() }
        }
    }

    /// Recently opened folders, most recent first — the order `noteRecentProject`
    /// keeps — then any folder open in the sidebar that predates that record. A
    /// folder deleted or renamed since is left out rather than offered as a row
    /// that opens nothing.
    ///
    /// Local projects only: a row here reopens its path with `addProject`, which is
    /// this Mac's folder picker's verb. A checkout on another machine has no local
    /// folder to reopen, and the path would land as a local project pointing at a
    /// directory that isn't here.
    private var recentEntries: [RecentProject] {
        var seen = Set<String>()
        var out: [RecentProject] = []
        for recent in settings.recentProjects where seen.insert(recent.path).inserted {
            out.append(recent)
        }
        for project in store.orderedProjects
        where !store.isOnAnotherDevice(project) && seen.insert(project.path).inserted {
            out.append(RecentProject(name: project.name, path: project.path))
        }
        return Array(
            out.lazy
                .filter { FileManager.default.fileExists(atPath: $0.path) }
                .prefix(8))
    }
}

// MARK: - Clone from GitHub

/// What the Clone from GitHub section is showing. Lives only as long as the
/// welcome page does: the connection is in the Keychain, so a remount re-reads it
/// and refetches the list rather than holding a copy that could go stale.
@MainActor
final class WelcomeRepositoriesModel: ObservableObject {
    enum Phase: Equatable {
        case disconnected
        case loading
        case loaded([GitHubRepository])
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading
    /// The signed-in login, shown beside the section label once the list loads.
    @Published private(set) var account: String?
    /// Why the stored connection stopped working, shown above Connect.
    @Published private(set) var connectionError: String?

    let connector = GitHubConnector()
    private var connectionObserver: AnyCancellable?

    init() {
        connectionObserver = NotificationCenter.default
            .publisher(for: GitHubIssueAuth.connectionDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
    }

    private func reload() {
        Task { await start() }
    }

    func start() async {
        guard let connection = GitHubIssueAuth.storedConnection() else {
            phase = .disconnected
            return
        }
        await load(connection)
    }

    func disconnect() {
        GitHubIssueAuth.deleteConnection()
    }

    private func load(_ connection: GitHubConnection) async {
        connectionError = nil
        phase = .loading
        let provider = GitHubIssueProvider(connection: connection)
        do {
            async let repositories = provider.repositories()
            async let login = provider.account()
            let (loaded, signedIn) = try await (repositories, login)
            account = signedIn
            phase = .loaded(loaded)
        } catch GitHubIssueProvider.APIError.status(401) {
            // A revoked or expired token: drop it and offer Connect again, the same
            // self-heal the Issues pane does on a 401. The deletion's reload lands on
            // `.disconnected` and keeps this explanation.
            GitHubIssueAuth.deleteConnection()
            account = nil
            connectionError = localized("GitHub no longer accepts the saved token. Connect again.")
            phase = .disconnected
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// The Clone from GitHub section: one card that holds Connect when no account is
/// linked, and otherwise a searchable, self-scrolling list of the account's
/// repositories, most recently pushed first. A row clones on whichever machine
/// the current workspace is on.
private struct WelcomeRepositories: View {
    @EnvironmentObject var store: FyoloStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var model = WelcomeRepositoriesModel()
    @State private var query = ""

    /// About six rows: enough to scan this week's work, short enough that the page
    /// itself never has to scroll to reach the bottom of the card.
    private let listHeight: CGFloat = 228

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            card
        }
        .task { await model.start() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            WelcomeSectionLabel(text: localized("Clone from GitHub"))
            Spacer(minLength: 0)
            if let account = model.account {
                Text("@\(account)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Menu {
                    Button(localized("Refresh")) { Task { await model.start() } }
                    Divider()
                    Button(localized("Disconnect GitHub")) { model.disconnect() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 14)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.trailing, 8)
            }
        }
    }

    /// Every state shares one card, filled like the Open Folder pill above it, so
    /// the section keeps its shape while it connects, loads, and lists.
    private var card: some View {
        content
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .disconnected:
            GitHubConnectView(
                connector: model.connector,
                title: localized("Your Repositories"),
                message: localized("Connect your GitHub account to clone one of your repositories."),
                hostError: model.connectionError
            )
            .padding(.vertical, 20)
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(height: listHeight)
        case .failed(let message):
            GitHubPrompt(
                title: localized("Couldn’t load"),
                message: localized("Something went wrong loading your repositories. Try again in a moment."),
                errorMessage: message
            ) {
                Button(localized("Try Again")) { Task { await model.start() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
            .padding(.vertical, 20)
        case .loaded(let repositories):
            loaded(repositories)
        }
    }

    @ViewBuilder
    private func loaded(_ repositories: [GitHubRepository]) -> some View {
        if repositories.isEmpty {
            WelcomeNote(text: localized("This GitHub account has no repositories yet."))
                .padding(.vertical, 14)
        } else {
            VStack(spacing: 6) {
                searchField
                list(filtered(repositories))
            }
            .padding(.top, 8)
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(localized("Search repositories"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(localized("Clear"))
            }
        }
        .capsuleField()
        .padding(.horizontal, 8)
    }

    /// The list scrolls inside the card with no scroller of its own: the top and
    /// bottom edges fade instead, which says "more" in the app's own chrome rather
    /// than with a system scroller that ignores the theme.
    private func list(_ matches: [GitHubRepository]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if matches.isEmpty {
                    WelcomeNote(text: localized("No repository matches."))
                        .padding(.top, 8)
                }
                ForEach(matches) { repository in
                    WelcomeRepositoryRow(repository: repository, chrome: chrome) {
                        store.cloneRepository(repository)
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .scrollIndicators(.never)
        .frame(height: listHeight)
        .mask(
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 10)
                Rectangle().fill(.black)
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 18)
            }
        )
    }

    private var chrome: ChromeTheme? { settings.chromeTheme(for: colorScheme) }

    private func filtered(_ repositories: [GitHubRepository]) -> [GitHubRepository] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return repositories }
        return repositories.filter { $0.fullName.localizedCaseInsensitiveContains(needle) }
    }
}

/// One repository: the owner's avatar, `owner/` dimmed ahead of the name, a lock
/// when private, and how long ago it was pushed — one line, so the card shows a
/// useful handful at once. Hover lifts it with the sidebar's own highlight.
private struct WelcomeRepositoryRow: View {
    let repository: GitHubRepository
    let chrome: ChromeTheme?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                avatar
                (Text(repository.owner.login + "/").foregroundStyle(.secondary)
                    + Text(repository.name).foregroundStyle(.primary))
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if repository.isPrivate {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .help(localized("Private"))
                }
                Spacer(minLength: 8)
                if let pushedAt = repository.pushedAt {
                    Text(pushedAt.formatted(.relative(presentation: .named)))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(SidebarRowHighlight(isSelected: false, isHovering: isHovering, chrome: chrome))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(localized("Clone \(repository.fullName)"))
    }

    private var avatar: some View {
        AsyncImage(url: repository.owner.avatarUrl) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Circle().fill(Color.primary.opacity(0.08))
        }
        .frame(width: 18, height: 18)
        .clipShape(Circle())
    }
}

// MARK: - Building blocks

/// A section heading, inset to line up with the rows beneath it.
private struct WelcomeSectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
            // Match the rows' inner inset (8pt) so the header lines up with the
            // labels below it rather than hanging off to the left.
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
    }
}

/// One line of secondary text in place of a list that has nothing to show.
private struct WelcomeNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
    }
}

/// A full-width welcome button: a leading glyph, a title, and an optional keyboard
/// shortcut, in a full-rounded pill that brightens under the cursor.
private struct WelcomeActionRow: View {
    private let icon: AnyView
    let title: String
    var shortcut: String?
    let action: () -> Void
    @State private var isHovering = false

    init(icon: some View, title: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.icon = AnyView(icon)
        self.title = title
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 12)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A full-rounded filled pill (Xcode's welcome buttons): a subtle fill at
            // rest so it reads as a button even without a cursor, brightening on hover.
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.12 : 0.06))
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovering)
    }
}

/// A two-line list row — glyph, title, and a quieter detail line — for the Recent
/// folders, lifted on hover with the sidebar's own themed highlight.
private struct WelcomeListRow: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    let icon: HugeIcon
    let title: String
    let subtitle: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                HugeIconView(icon: icon, size: 15, color: .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SidebarRowHighlight(isSelected: false, isHovering: isHovering, chrome: chrome))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var chrome: ChromeTheme? { settings.chromeTheme(for: colorScheme) }
}
