import AppKit
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
/// `presentOpenProjectPanel`, `cloneRepository`, and the GitHub connect flow the
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
/// welcome page does: the token is in the Keychain, so a remount re-reads it and
/// refetches the list rather than holding a copy that could go stale.
@MainActor
final class WelcomeRepositoriesModel: ObservableObject {
    enum Phase: Equatable {
        case disconnected
        case connecting(userCode: String)
        case loading
        case loaded([GitHubRepository])
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading
    /// Why the last Connect failed, shown under the button.
    @Published private(set) var connectError: String?

    func start() async {
        guard let token = GitHubIssueAuth.storedToken() else {
            phase = .disconnected
            return
        }
        await load(token: token)
    }

    func connect() async {
        connectError = nil
        do {
            let token = try await GitHubIssueAuth.connect { phase = .connecting(userCode: $0) }
            await load(token: token)
        } catch {
            phase = .disconnected
            connectError = error.localizedDescription
        }
    }

    private func load(token: String) async {
        phase = .loading
        do {
            phase = .loaded(try await GitHubIssueProvider(token: token).repositories())
        } catch GitHubIssueProvider.APIError.status(401) {
            // A revoked token: drop it and offer Connect again, the same self-heal
            // the Issues pane does on a 401.
            GitHubIssueAuth.deleteToken()
            phase = .disconnected
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// The Clone from GitHub section: Connect when no account is linked, otherwise a
/// searchable list of the account's repositories, most recently pushed first. A
/// row clones on whichever machine the current workspace is on.
private struct WelcomeRepositories: View {
    @EnvironmentObject var store: FyoloStore
    @StateObject private var model = WelcomeRepositoriesModel()
    @State private var query = ""

    /// Enough to cover what someone is working on this week; the search reaches
    /// the rest without growing the page into a scroll inside a scroll.
    private let visibleLimit = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            WelcomeSectionLabel(text: localized("Clone from GitHub"))
            content
        }
        .task { await model.start() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .disconnected, .connecting:
            GitHubConnectPrompt(
                title: localized("Your Repositories"),
                message: localized("Connect your GitHub account to clone one of your repositories."),
                userCode: {
                    if case .connecting(let userCode) = model.phase { return userCode }
                    return nil
                }(),
                errorMessage: model.connectError
            ) { Task { await model.connect() } }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
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
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        case .loaded(let repositories):
            loaded(repositories)
        }
    }

    @ViewBuilder
    private func loaded(_ repositories: [GitHubRepository]) -> some View {
        if repositories.isEmpty {
            WelcomeNote(text: localized("This GitHub account has no repositories yet."))
        } else {
            TextField(localized("Search repositories"), text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            let matches = filtered(repositories)
            if matches.isEmpty {
                WelcomeNote(text: localized("No repository matches."))
            }
            ForEach(matches.prefix(visibleLimit)) { repository in
                WelcomeListRow(
                    icon: .github,
                    title: repository.fullName,
                    subtitle: subtitle(for: repository)
                ) { store.cloneRepository(repository) }
            }
        }
    }

    private func filtered(_ repositories: [GitHubRepository]) -> [GitHubRepository] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return repositories }
        return repositories.filter { $0.fullName.localizedCaseInsensitiveContains(needle) }
    }

    private func subtitle(for repository: GitHubRepository) -> String {
        var parts: [String] = []
        if repository.isPrivate { parts.append(localized("Private")) }
        if let pushedAt = repository.pushedAt {
            parts.append(pushedAt.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
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

/// A two-line list row — glyph, title, and a quieter detail line — shared by the
/// Recent folders and the GitHub repositories so both lists read as one page.
private struct WelcomeListRow: View {
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
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovering)
    }
}
