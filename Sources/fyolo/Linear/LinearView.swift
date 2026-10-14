import AppKit
import SwiftUI

// MARK: - Plugin

/// The Linear pane, as a plugin: the inspector's Linear segment exists only
/// while this is switched on in Settings ▸ Plugins.
struct LinearPlugin: FyoloPlugin {
    static let id = "linear"

    var id: String { Self.id }
    var name: String { localized("Linear") }
    var summary: String {
        localized("Shows this project’s Linear tickets in the inspector, with the pull requests that name them.")
    }
}

// MARK: - Pane

/// The inspector's Linear pane: the project's team tickets, the viewer's own
/// first, each carrying chips for the pull requests whose titles name it.
/// Clicking a ticket pushes its page into the pane. Read-only on purpose —
/// agents write to Linear through its MCP server.
struct LinearView: View {
    @EnvironmentObject var store: FyoloStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    let projectRoot: String
    @StateObject private var model: LinearPanelModel
    @State private var searchText = ""

    init(projectRoot: String, settings: AppSettings) {
        self.projectRoot = projectRoot
        _model = StateObject(wrappedValue: LinearPanelModel(
            projectRoot: projectRoot,
            gitHubEnabled: { [weak settings] in settings?.githubIntegrationEnabled ?? false }
        ))
    }

    var body: some View {
        Group {
            if let key = model.path.last {
                LinearIssueDetailView(key: key, model: model, settings: settings)
                    .id(key)
            } else {
                listPane
            }
        }
        .task(id: projectRoot) { await model.start() }
        .onChange(of: settings.githubIntegrationEnabled) { _, _ in
            Task { await model.loadPullRequests(force: false) }
        }
    }

    // MARK: List

    @ViewBuilder
    private var listPane: some View {
        switch model.phase {
        case .disconnected:
            LinearConnectView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .choosingTeam:
            teamChooser
        case .ready:
            VStack(spacing: 0) {
                topBar
                listBody
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 2) {
            teamMenu
            Spacer(minLength: 0)
            searchField
            TreeHeaderButton(codicon: .refresh, help: localized("Refresh")) {
                Task { await model.reload(force: true) }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(height: GitChangesView.topBarHeight)
    }

    private var teamMenu: some View {
        Menu {
            if model.teams.count > 1 {
                Picker(localized("Team"), selection: Binding(
                    get: { model.team?.id ?? "" },
                    set: { id in model.teams.first { $0.id == id }.map(model.choose) }
                )) {
                    ForEach(model.teams) { team in
                        Text(team.name).tag(team.id)
                    }
                }
                .pickerStyle(.inline)
                Divider()
            }
            Button(localized("Disconnect Linear")) { model.disconnect() }
        } label: {
            Text(model.team?.name ?? localized("Linear"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 6)
        .help(localized("Choose which team’s tickets to show"))
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(localized("Search"), text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .onExitCommand { searchText = "" }
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .frame(minWidth: 56, maxWidth: 120)
        .background { CapsuleFieldChrome() }
        .padding(.trailing, 4)
    }

    @ViewBuilder
    private var listBody: some View {
        let mine = model.mine.filter { $0.matches(search: searchText) }
        let others = model.others.filter { $0.matches(search: searchText) }
        if let error = model.errorMessage, model.mine.isEmpty, model.others.isEmpty {
            GitHubPrompt(title: localized("Couldn’t load"), message: error, errorMessage: nil, icon: .linear) {
                if model.needsReconnect {
                    Button(localized("Connect Again")) { model.disconnect() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(localized("Try Again")) { Task { await model.reload(force: true) } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isLoading, model.mine.isEmpty, model.others.isEmpty {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.mine.isEmpty, model.others.isEmpty {
            PaneEmptyState(
                localized("No Open Tickets"), icon: .checkCircle,
                message: localized("\(model.team?.name ?? "") has nothing open right now."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if mine.isEmpty, others.isEmpty {
            PaneEmptyState(localized("No Matches"), icon: .search)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    section(localized("Assigned to Me"), mine)
                    section(localized("Everyone Else"), others)
                }
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ issues: [LinearIssue]) -> some View {
        if !issues.isEmpty {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)
            ForEach(issues) { issue in
                LinearIssueRow(
                    issue: issue,
                    pullRequests: model.pullRequestIndex[issue.identifier] ?? [],
                    font: settings.interfaceFont,
                    chrome: settings.chromeTheme(for: colorScheme)
                ) { model.open(issue.id) }
            }
        }
    }

    private var teamChooser: some View {
        GitHubPrompt(
            title: localized("Choose a Team"),
            message: localized("Pick the Linear team whose tickets belong to this project. Fyolo remembers it."),
            errorMessage: model.errorMessage,
            icon: .linear
        ) {
            VStack(spacing: 6) {
                ForEach(model.teams) { team in
                    Button { model.choose(team) } label: {
                        HStack {
                            Text(team.name)
                            Spacer()
                            Text(team.key).foregroundStyle(.secondary).font(.system(size: 11, design: .monospaced))
                        }
                        .frame(maxWidth: 220)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row

/// One ticket: priority, a state dot in the team's own state color, the
/// identifier and title, and a chip per linked pull request in its status
/// color. The assignee and age appear on hover, like the Issues rows.
private struct LinearIssueRow: View {
    let issue: LinearIssue
    let pullRequests: [LinkedPullRequest]
    let font: Font
    let chrome: ChromeTheme?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            LinearPriorityGlyph(priority: issue.priority)
            Circle()
                .strokeBorder(issue.state.tint, lineWidth: 1.5)
                .background(Circle().fill(issue.state.type == "started" ? issue.state.tint : .clear).padding(2.5))
                .frame(width: 10, height: 10)
                .help(issue.state.name)
            Text(issue.identifier)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Text(issue.title)
                .font(font)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 6)
            if isHovering, let assignee = issue.assignee {
                Text(assignee.displayName)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            ForEach(pullRequests.prefix(2)) { pullRequest in
                LinkedPullRequestChip(pullRequest: pullRequest)
            }
            if pullRequests.count > 2 {
                Text("+\(pullRequests.count - 2)")
                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(SidebarRowHighlight(isSelected: false, isHovering: isHovering, chrome: chrome))
        .onHover { isHovering = $0 }
        .onTapGesture(perform: action)
        .help(issue.title)
    }
}

/// Linear's priority marks: an exclamation square for urgent, rising bars for
/// high, medium and low, a dash for none.
private struct LinearPriorityGlyph: View {
    let priority: Double

    var body: some View {
        Group {
            switch Int(priority) {
            case 1:
                Image(systemName: "exclamationmark.square.fill").foregroundStyle(.orange)
            case 2, 3, 4:
                Image(systemName: "cellularbars", variableValue: [0, 1.0, 0.66, 0.33][Int(priority) - 1])
                    .foregroundStyle(.secondary)
            default:
                Image(systemName: "minus").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .frame(width: 13)
        .help(LinearPriority.label(priority))
    }
}

/// `#123` in the pull request's status color; clicking opens it on GitHub.
struct LinkedPullRequestChip: View {
    let pullRequest: LinkedPullRequest

    var body: some View {
        Button {
            NSWorkspace.shared.open(pullRequest.url)
        } label: {
            Text("#\(pullRequest.number)")
                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(pullRequest.status.tint)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(pullRequest.status.tint.opacity(0.14)))
                .overlay(Capsule().strokeBorder(pullRequest.status.tint.opacity(0.35), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("\(pullRequest.status.label) · \(pullRequest.repository)#\(pullRequest.number) \(pullRequest.title)")
    }
}

// MARK: - Connect

/// Sign in with Linear leads; a pasted personal API key is one click away for
/// workspaces whose admins don't allow OAuth applications.
private struct LinearConnectView: View {
    @ObservedObject var model: LinearPanelModel
    @State private var showsKeyField = false
    @State private var apiKey = ""

    var body: some View {
        GitHubPrompt(
            title: localized("Linear"),
            message: localized("Sign in to see this project’s Linear tickets, with the pull requests that name them."),
            errorMessage: model.connectError,
            icon: .linear
        ) {
            VStack(spacing: 8) {
                Button {
                    model.signIn()
                } label: {
                    if model.isSigningIn, !showsKeyField {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(localized("Sign In with Linear"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isSigningIn)

                if showsKeyField {
                    SecureField(localized("API key"), text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                        .onSubmit { model.connect(apiKey: apiKey) }
                    HStack(spacing: 10) {
                        Button(localized("Connect")) { model.connect(apiKey: apiKey) }
                            .controlSize(.small)
                            .disabled(model.isSigningIn)
                        if let url = LinearAuth.apiKeySettingsURL {
                            Link(localized("Create a Key…"), destination: url)
                                .font(.system(size: 11))
                        }
                    }
                } else {
                    Button(localized("Use an API Key Instead")) { showsKeyField = true }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Detail

/// A ticket pushed into the pane: a native header to go back or out to Linear,
/// over the page — state, priority, people, labels, pull requests, linked
/// tickets, the description and the comments — in the issue web view.
private struct LinearIssueDetailView: View {
    let key: String
    @ObservedObject var model: LinearPanelModel
    @ObservedObject var settings: AppSettings

    @EnvironmentObject private var store: FyoloStore
    @Environment(\.colorScheme) private var colorScheme

    private var detail: LinearIssueDetail? { model.details[key] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            content
        }
        .background(Color(nsColor: settings.terminalBackgroundColor))
        .task(id: key) { await model.loadDetail(key) }
        .onExitCommand { model.back() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: model.back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.path.count > 1 ? localized("Back") : localized("All Tickets"))
            Text(detail?.identifier ?? key)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Text(detail?.title ?? "")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if let url = detail?.url {
                TreeHeaderButton(huge: .squareArrowUpRight, help: localized("Open in Linear")) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: GitChangesView.topBarHeight)
    }

    @ViewBuilder
    private var content: some View {
        if let detail {
            let theme = DocumentTheme.resolve(settings: settings, colorScheme: colorScheme)
            IssueWebView(
                html: LinearDetailHTML.page(
                    detail, pullRequests: model.pullRequests(for: detail.identifier), theme: theme),
                openLink: { url in
                    if url.scheme == LinearDetailHTML.ticketScheme, let id = url.host {
                        model.open(id)
                        return true
                    }
                    return model.openIfTicket(url)
                },
                addToChat: { selection in
                    if let selection {
                        _ = store.addSnippetToSelectedSessionPrompt(selection)
                    } else {
                        _ = store.addPathToSelectedSessionPrompt(detail.url)
                    }
                },
                canAddToChat: { store.selectedSessionRunsAgent }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.detailError {
            PaneEmptyState(localized("Couldn’t load"), icon: .linear, message: error)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The ticket page, built on the Issues detail's stylesheet and markdown so a
/// Linear ticket reads exactly like a GitHub issue beside it.
enum LinearDetailHTML {
    /// Links to another ticket carry its id under this scheme, so the pane
    /// pushes the ticket instead of opening the browser.
    static let ticketScheme = "x-fyolo-linear"

    static func page(_ detail: LinearIssueDetail, pullRequests: [LinkedPullRequest], theme: DocumentTheme) -> String {
        let escape = IssueDetailHTML.escape
        let state = "<span class=\"state\" style=\"color:\(cssColor(detail.state.color))\">\(escape(detail.state.name))</span>"
        var meta = [state, escape(LinearPriority.label(detail.priority))]
        if let assignee = detail.assignee {
            meta.append(IssueDetailHTML.avatar(assignee.avatarUrl.flatMap(URL.init(string:))) + escape(assignee.displayName))
        } else {
            meta.append(escape(localized("Unassigned")))
        }
        let opened = detail.creator.map {
            localized("\(escape($0.displayName)) opened \(IssueDetailHTML.relative(detail.createdAt))")
        } ?? IssueDetailHTML.relative(detail.createdAt)

        let labels = detail.labels.nodes.map {
            "<span class=\"label\" style=\"border-color:\(cssColor($0.color))\">\(escape($0.name))</span>"
        }.joined()

        let chips = pullRequests.map { pullRequest in
            "<a class=\"pr \(pullRequest.status.cssClass)\" href=\"\(escape(pullRequest.url.absoluteString))\" "
                + "title=\"\(escape(pullRequest.repository))\">#\(pullRequest.number) "
                + "<span>\(escape(pullRequest.status.label))</span> \(escape(pullRequest.title))</a>"
        }.joined()

        let linked = detail.linkedTickets.map { group in
            let rows = group.tickets.map { ticket in
                "<li><span class=\"dot\" style=\"background:\(cssColor(ticket.state.color))\"></span>"
                    + "<a href=\"\(ticketScheme)://\(escape(ticket.id))\"><code>\(escape(ticket.identifier))</code> "
                    + "\(escape(ticket.title))</a></li>"
            }.joined()
            return "<div class=\"group\"><h4>\(escape(group.title))</h4><ul class=\"tickets\">\(rows)</ul></div>"
        }.joined()

        let body = (detail.description ?? "").isEmpty
            ? "<p class=\"empty\">\(localized("No description provided."))</p>"
            : MarkdownHTML.html(detail.description ?? "", documentMode: true)
        let comments = detail.thread.map { comment in
            """
            <section class="comment">
            <div class="who">\(IssueDetailHTML.avatar(comment.user?.avatarUrl.flatMap(URL.init(string:))))<b>\(escape(comment.author))</b> · \(IssueDetailHTML.relative(comment.createdAt))</div>
            \(MarkdownHTML.html(comment.body, documentMode: true))
            </section>
            """
        }.joined()

        let page = """
        <!doctype html><html><head><meta charset="utf-8">
        <style>\(IssueDetailHTML.css(theme))\(css(theme))</style></head><body>
        <header>
        <h1>\(escape(detail.title))</h1>
        <div class="meta">\(escape(detail.identifier)) · \(meta.joined(separator: " · ")) · \(opened)</div>
        \(labels.isEmpty ? "" : "<div class=\"labels\">\(labels)</div>")
        </header>
        \(chips.isEmpty ? "" : "<div class=\"prs\"><h4>\(localized("Pull Requests"))</h4>\(chips)</div>")
        \(linked.isEmpty ? "" : "<div class=\"linked\">\(linked)</div>")
        <article class="body">\(body)</article>
        \(comments)
        </body></html>
        """
        return IssueDetailHTML.routeImages(page)
    }

    /// Linear hands colors back as `#rrggbb`; anything else falls back to grey
    /// rather than reaching the stylesheet unescaped.
    private static func cssColor(_ value: String) -> String {
        let hex = value.drop { $0 == "#" }
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return "#888888" }
        return "#" + hex
    }

    private static func css(_ theme: DocumentTheme) -> String {
        """
        h4 { font-size: 10.5px; text-transform: uppercase; letter-spacing: .05em;
             color: \(theme.secondary); margin: 14px 0 6px; }
        .prs a.pr { display: block; text-decoration: none; color: \(theme.foreground);
                    border-left: 3px solid var(--pr); padding: 4px 8px; margin: 0 0 4px;
                    border-radius: 4px; background: \(theme.panel); font-size: 12px;
                    white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .prs a.pr span { color: var(--pr); font-weight: 600; margin-right: 4px; }
        .pr.merged { --pr: #a371f7; } .pr.closed, .pr.failing { --pr: #f85149; }
        .pr.draft { --pr: #8b949e; } .pr.pending { --pr: #d29922; }
        .pr.review { --pr: #fb8500; } .pr.ready { --pr: #3fb950; } .pr.open { --pr: #4493f8; }
        ul.tickets { list-style: none; padding: 0; margin: 0; }
        ul.tickets li { padding: 2px 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        ul.tickets a { color: \(theme.foreground); }
        ul.tickets code { background: none; padding: 0; color: \(theme.secondary); }
        .dot { display: inline-block; width: 7px; height: 7px; border-radius: 50%; margin-right: 6px; }
        """
    }
}
