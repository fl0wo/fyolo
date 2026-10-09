import SwiftUI
import FyoloShared
import UIKit

/// The root screen: one workspace's project list, with a "Needs You" strip
/// pinned above it. GitHub-mobile shape — the backbone is "what do I have open"
/// (one row per project, with a status summary so nothing needs opening to check
/// on), while the strip keeps the phone's highest-frequency question ("which
/// agent is waiting on me?") answerable at a glance and one tap from its
/// terminal.
///
/// Slack's split: the title names the workspace you are in, the rail switches
/// it, and the list underneath is only ever that one workspace's. The strip is
/// the deliberate exception — it crosses every workspace, which is what makes
/// showing one at a time safe.
///
/// Tapping a project pushes its page (sessions + new-session). Lives at the root
/// of the home navigation stack inside RootContainerViewController.
final class ProjectListViewController: UIViewController {
    private let store: RosterStore
    /// The workspace on screen. The strip above the list ignores it — see
    /// `refilter`.
    private let scope: WorkspaceScope
    /// Reveal the shell's workspace rail. The shell owns the panel, so the
    /// title-bar opener only asks for it.
    var onOpenWorkspaceRail: (() -> Void)?

    private enum Section {
        case needsYou
        case projects
    }

    /// The sections currently on screen, rebuilt on every roster change.
    private var sections: [Section] = []
    /// Cross-workspace attention sessions (the strip's rows).
    private var attention: [MockSession] = []
    /// The workspace's projects, in roster order. Chats- and Terminals-kind
    /// containers are excluded: they have their own tabs.
    private var projects: [MockProject] = []

    /// Mirrors the Mac sidebar's sort pull-down. The roster arrives in the
    /// Mac's recent-activity order, so "Recent Activity" means "as pushed";
    /// "Name" re-sorts locally A→Z.
    private var sortByName = UserDefaults.standard.string(forKey: "sessions.sortOrder") == "name"

    private let filterButton = UIButton(type: .system)
    /// Opens the workspace rail: the title itself is the control, Slack's shape.
    /// Disabled whenever the rail is absent (one workspace, or none yet), so the
    /// common case keeps exactly the title bar it had.
    private let workspaceButton = UIButton(type: .custom)
    /// The mark that says the title opens something. Absent with the rail.
    private let workspaceChevron = UIImageView()
    /// The workspace in scope, and the machine it is on when that needs saying.
    private let pageTitle = UILabel()
    private let machineLabel = UILabel()
    private let tableView = UITableView(frame: .zero, style: .grouped)
    /// The Telegram/iMessage-style zero state shown when there are no projects
    /// to list — never fake rows. Its copy tracks `CompanionLink.state`.
    private let emptyState = ListEmptyStateView()
    /// Set once a `.connecting` state has lingered past the grace window, so the
    /// zero state escalates from "Connecting…" to "Can't reach your Mac".
    private var reconnectStalled = false
    private var connectingGraceTimer: Timer?
    private var rosterObserver: NSObjectProtocol?
    private var linkStateObserver: NSObjectProtocol?
    private var themeObserver: NSObjectProtocol?
    private var workspaceObserver: NSObjectProtocol?

    init(store: RosterStore, scope: WorkspaceScope) {
        self.store = store
        self.scope = scope
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // A full page, not a drawer. Tinted to the terminal theme so the whole
        // app reads as one canvas (the rows/table draw clear over it).
        themeObserver = installThemeBackdrop()
        let topBar = configureTopBar()
        configureTable(below: topBar)
        configureEmptyState(below: topBar)
        refilter()
        rosterObserver = NotificationCenter.default.addObserver(
            forName: RosterStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refilter() }
        }
        // The zero-state copy ("No Mac connected" → "Connecting…" → the empty
        // roster) follows the live link state, not just roster pushes.
        linkStateObserver = NotificationCenter.default.addObserver(
            forName: CompanionLink.stateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateEmptyState() }
        }
        workspaceObserver = NotificationCenter.default.addObserver(
            forName: WorkspaceScope.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refilter() }
        }
    }

    deinit {
        let observers = [rosterObserver, linkStateObserver, themeObserver, workspaceObserver]
        for observer in observers.compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        connectingGraceTimer?.invalidate()
    }

    func refresh() {
        tableView.reloadData()
    }

    // MARK: - Top bar (large title + sort)

    private func configureTopBar() -> UIView {
        // The workspace's own name, not the tab's — the title bar says which
        // context you are in, and the rail is what changes it. A roster that
        // never names a workspace (the bundled mock, an older Mac) falls back to
        // the tab's word, so those screens read exactly as they did.
        pageTitle.font = .systemFont(ofSize: 34, weight: .bold)
        pageTitle.textColor = .label
        pageTitle.lineBreakMode = .byTruncatingTail

        // Which machine the workspace is on, under its name. It used to ride the
        // section header; with the header gone the claim belongs to the thing it
        // qualifies. Hidden for the Mac you paired with — being on that machine
        // is the absence of a mark.
        machineLabel.font = .systemFont(ofSize: 13, weight: .regular)
        machineLabel.textColor = .secondaryLabel
        machineLabel.lineBreakMode = .byTruncatingTail
        machineLabel.isHidden = true

        // Slack's workspace switcher: a chevron on the name, not a control beside
        // it. The name is what changes, so the name is what you press — and the
        // title bar keeps one object instead of a glass circle competing with it.
        // Hidden by default: a hidden arranged subview contributes neither width
        // nor spacing, so a one-workspace title bar is untouched.
        workspaceChevron.image = UIImage(
            systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)
        )
        workspaceChevron.tintColor = .label
        workspaceChevron.contentMode = .center
        workspaceChevron.setContentHuggingPriority(.required, for: .horizontal)
        workspaceChevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        workspaceChevron.isHidden = true

        let titleRow = UIStackView(arrangedSubviews: [pageTitle, workspaceChevron])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 8
        titleRow.isUserInteractionEnabled = false
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        workspaceButton.addSubview(titleRow)
        workspaceButton.accessibilityIdentifier = "home.workspaceRail"
        // The name is the identity; the sort button never gives way for it. The
        // whole title unit yields, so the chevron stays glued to the truncation.
        workspaceButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        workspaceButton.addAction(UIAction { [weak self] _ in
            self?.onOpenWorkspaceRail?()
        }, for: .touchUpInside)
        // The press cue a title-as-button needs, since it has no fill to shade.
        let pressStates: [(UIControl.Event, CGFloat)] = [
            (.touchDown, 0.4), (.touchUpInside, 1), (.touchUpOutside, 1),
            (.touchCancel, 1), (.touchDragExit, 1),
        ]
        for (event, alpha) in pressStates {
            workspaceButton.addAction(UIAction { _ in titleRow.alpha = alpha }, for: event)
        }
        NSLayoutConstraint.activate([
            titleRow.leadingAnchor.constraint(equalTo: workspaceButton.leadingAnchor),
            titleRow.trailingAnchor.constraint(equalTo: workspaceButton.trailingAnchor),
            titleRow.topAnchor.constraint(equalTo: workspaceButton.topAnchor),
            titleRow.bottomAnchor.constraint(equalTo: workspaceButton.bottomAnchor),
        ])

        let titleStack = UIStackView(arrangedSubviews: [workspaceButton, machineLabel])
        titleStack.axis = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 0

        // The Mac sidebar's sort pull-down, translated to iMessage chrome:
        // a glass circle riding the large title, menu as primary action.
        filterButton.applyGlassSymbol("line.3.horizontal.decrease")
        filterButton.accessibilityLabel = localized("Sort")
        filterButton.showsMenuAsPrimaryAction = true
        filterButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.sortMenuItems() ?? [])
            },
        ])

        let spacer = UIView()
        let bar = UIStackView(arrangedSubviews: [titleStack, spacer, filterButton])
        bar.axis = .horizontal
        bar.alignment = .center
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            // Telegram's nav-bar glass buttons are 40pt circles.
            filterButton.widthAnchor.constraint(equalToConstant: 40),
            filterButton.heightAnchor.constraint(equalToConstant: 40),
        ])
        return bar
    }

    /// The same two orders as the Mac's sort menu, checkmarked like it too.
    private func sortMenuItems() -> [UIMenuElement] {
        [
            UIAction(title: localized("Recent Activity"), state: sortByName ? .off : .on) { [weak self] _ in
                self?.setSortByName(false)
            },
            UIAction(title: localized("Name"), state: sortByName ? .on : .off) { [weak self] _ in
                self?.setSortByName(true)
            },
        ]
    }

    private func setSortByName(_ byName: Bool) {
        sortByName = byName
        UserDefaults.standard.set(byName ? "name" : "recentActivity", forKey: "sessions.sortOrder")
        refilter()
    }

    private func presentSettings(deepLinkToDevices: Bool = false) {
        // The sheet inherits the window's app-wide Appearance override, same
        // as every other screen.
        let nav = UINavigationController(rootViewController: SettingsViewController())
        if deepLinkToDevices {
            // "Connect a Mac" promises pairing, so land on the Devices page
            // itself; back reveals full Settings, swipe-down dismisses.
            nav.pushViewController(DevicesSettingsViewController(), animated: false)
        }
        present(nav, animated: true)
    }

    // MARK: - Table

    private func configureTable(below topBar: UIView) {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        // Hairlines between rows are drawn inside the rows (RowSeparator):
        // grouped tables render their own separators full-width at section
        // edges, which fights the whitespace-gap grouping.
        tableView.separatorStyle = .none
        tableView.sectionHeaderTopPadding = 0
        // Groups are split by whitespace, not a line: a fixed footer gap under
        // each group. Zeroing the *estimates* keeps the table from adding its
        // own phantom footer height on top of ours.
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0
        tableView.keyboardDismissMode = .onDrag
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        tableView.register(
            SectionCapView.self,
            forHeaderFooterViewReuseIdentifier: SectionCapView.reuseID
        )
        tableView.translatesAutoresizingMaskIntoConstraints = false
        // The native tab controller contributes the correct safe-area and
        // adjusted scroll insets for both the classic and Liquid Glass bars.
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 16),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Rebuild the page from the store: the attention strip (only when
    /// non-empty), then the workspace in scope. The loose funnels (Chats,
    /// Terminals) belong to their own tabs, so they're kept out of the folder
    /// list — their attention sessions still surface in the strip here, the
    /// cross-cutting shortcut.
    ///
    /// The roster's order is the Mac sidebar's order; "Name" re-sorts locally.
    private func refilter() {
        // Read straight from the store, past the workspace scope. "Needs You" is
        // the cross-workspace question the phone is opened to answer, so it is
        // never scoped — a blocked agent in a workspace that isn't on screen is
        // exactly the one that would otherwise go unnoticed. It is also what
        // makes showing one workspace at a time safe.
        attention = store.attentionSessions
        projects = store.projects.filter {
            $0.kind != "chats" && $0.kind != "terminals" && scope.admits($0)
        }
        if sortByName {
            projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        sections = (attention.isEmpty ? [] : [.needsYou]) + (projects.isEmpty ? [] : [.projects])
        updateTitle()
        tableView.reloadData()
        updateEmptyState()
    }

    /// The title names the workspace on screen, with its machine underneath when
    /// that isn't the paired Mac. The opener beside it appears only when there is
    /// a second workspace to reach — one workspace is no choice at all, and the
    /// title then just reads its name.
    private func updateTitle() {
        let machines = RailMachine.roster(from: store.projects)
        let workspace = machines.workspace(id: scope.selectedID)
        let name = workspace?.name ?? ""
        pageTitle.text = name.isEmpty ? localized("Projects") : name
        machineLabel.text = workspace?.machineLabel
        machineLabel.isHidden = workspace?.machineLabel == nil
        let hasOtherWorkspaces = machines.workspaceCount > 1
        workspaceChevron.isHidden = !hasOtherWorkspaces
        workspaceButton.isEnabled = hasOtherWorkspaces
        // With nowhere to switch to, the title is a title again: the button stops
        // being an element of its own so VoiceOver reads the name underneath.
        workspaceButton.isAccessibilityElement = hasOtherWorkspaces
        workspaceButton.accessibilityLabel = localized("Workspaces")
        workspaceButton.accessibilityValue = pageTitle.text
    }

    // MARK: - Empty state

    private func configureEmptyState(below topBar: UIView) {
        emptyState.isHidden = true
        // The button's job depends on the state: unpaired → go pair a Mac in
        // Settings; stalled reconnect → kick the socket now ("Try Again").
        emptyState.onAction = { [weak self] in self?.emptyStateAction() }
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 16),
            emptyState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Show the zero state only when there are genuinely no rows, and phrase it
    /// for where the link is: unpaired (onboard), connecting (reassure) →
    /// stalled (the Mac isn't answering — offer Try Again), or connected-but-idle
    /// (nudge toward opening a project on the Mac).
    private func updateEmptyState() {
        emptyState.isHidden = !projects.isEmpty || !attention.isEmpty
        guard !emptyState.isHidden else {
            stopConnectingGraceTimer()
            return
        }
        switch CompanionLink.state {
        case .unpaired:
            stopConnectingGraceTimer()
            reconnectStalled = false
            emptyState.configure(
                icon: .devicePair,
                title: localized("No Mac connected"),
                message: localized("Open Fyolo on your Mac, then pair this phone to see and drive your projects from here."),
                actionTitle: localized("Connect a Mac"),
                busy: false
            )
        case .connecting where reconnectStalled:
            // The socket has been down long enough that the Mac is probably
            // asleep or off-network. Say so, and let the user force a retry —
            // the link keeps trying on its slow heartbeat regardless.
            emptyState.configure(
                icon: .wifiError,
                title: localized("Can't reach your Mac"),
                message: localized("It may be asleep or off your network. Fyolo keeps trying — reopen the lid, or tap to retry now."),
                actionTitle: localized("Try Again"),
                busy: false
            )
        case .connecting:
            startConnectingGraceTimer()
            emptyState.configure(
                icon: nil,
                title: localized("Connecting…"),
                message: localized("Reaching your Mac over the companion link."),
                actionTitle: nil,
                busy: true
            )
        case .connected:
            stopConnectingGraceTimer()
            reconnectStalled = false
            emptyState.configure(
                icon: .folder,
                title: localized("No projects open"),
                message: localized("Open a project in Fyolo on your Mac and it'll show up here."),
                actionTitle: nil,
                busy: false
            )
        case .failed(let reason):
            stopConnectingGraceTimer()
            reconnectStalled = false
            emptyState.configure(
                icon: .wifiError,
                title: localized("Connection failed"),
                message: reason,
                actionTitle: localized("Open Settings"),
                busy: false
            )
        }
    }

    /// After ~15s of unbroken "Connecting…", assume the Mac isn't coming right
    /// back and escalate the copy. Foreground/path events that reconnect will
    /// flip the state to `.connected` and cancel this.
    private func startConnectingGraceTimer() {
        guard connectingGraceTimer == nil, !reconnectStalled else { return }
        connectingGraceTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.connectingGraceTimer = nil
                self.reconnectStalled = true
                self.updateEmptyState()
            }
        }
    }

    private func stopConnectingGraceTimer() {
        connectingGraceTimer?.invalidate()
        connectingGraceTimer = nil
    }

    /// The zero-state button. Unpaired → open pairing; stalled → force an
    /// immediate reconnect and drop back to the "Connecting…" copy.
    private func emptyStateAction() {
        if case .unpaired = CompanionLink.state {
            presentSettings(deepLinkToDevices: true)
            return
        }
        if case .failed = CompanionLink.state {
            presentSettings(deepLinkToDevices: true)
            return
        }
        reconnectStalled = false
        updateEmptyState()
        store.reconnectNow()
    }
}

/// The Projects root shows one workspace at a time, so the shell arms the rail's
/// edge gesture here.
extension ProjectListViewController: WorkspaceScoped {}

// MARK: - Table data source / delegate

extension ProjectListViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .needsYou: attention.count
        case .projects: projects.count
        }
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard showsHeaders else { return nil }
        guard let header = tableView.dequeueReusableHeaderFooterView(
            withIdentifier: SectionCapView.reuseID
        ) as? SectionCapView else { return nil }
        switch sections[section] {
        case .needsYou:
            header.configure(title: localized("Needs You"))
        case .projects:
            // "Projects", never the workspace's name: the title above already
            // says which workspace this is, and a caption repeating it is the
            // section header the title replaced.
            header.configure(title: localized("Projects"))
        }
        return header
    }

    /// Headers only earn their space once the strip splits the page in two —
    /// with a single section the caption would name what the title just named.
    private var showsHeaders: Bool {
        sections.count > 1
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        showsHeaders ? 28 : 0
    }

    /// A whitespace gap below each group — the divider-free separator,
    /// matching the macOS sidebar's spacing-based grouping.
    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        12
    }

    /// An empty (transparent) footer view, so the gap above is just whitespace.
    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        UIView()
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        cell.selectionStyle = .none
        cell.backgroundColor = .clear
        switch sections[indexPath.section] {
        case .needsYou:
            let session = attention[indexPath.row]
            cell.contentConfiguration = UIHostingConfiguration {
                SessionRow(
                    session: session,
                    isCurrent: session.key == store.currentSessionKey,
                    showsProject: true,
                    showsSeparator: indexPath.row < attention.count - 1
                )
            }
            .margins(.horizontal, 12)
            .margins(.vertical, 0)
        case .projects:
            cell.contentConfiguration = UIHostingConfiguration {
                ProjectRow(
                    project: projects[indexPath.row],
                    showsSeparator: indexPath.row < projects.count - 1
                )
            }
            .margins(.horizontal, 12)
            .margins(.vertical, 0)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch sections[indexPath.section] {
        case .needsYou:
            // Straight to the terminal — the strip exists so the blocked
            // session is one tap away, never behind its project page.
            store.openSession(attention[indexPath.row])
        case .projects:
            navigationController?.pushViewController(
                ProjectDetailViewController(store: store, project: projects[indexPath.row]),
                animated: true
            )
        }
    }

    /// Trailing swipe on a strip row: the Mac session menu's "Close Session".
    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard case .needsYou = sections[indexPath.section],
              store.deviceEndpoint != nil,
              let sessionID = attention[indexPath.row].rosterID
        else { return nil }
        let close = UIContextualAction(style: .destructive, title: localized("Close")) { [weak self] _, _, done in
            self?.store.stopSession(sessionID)
            done(true)
        }
        close.image = UIImage(systemName: "xmark.circle")
        return UISwipeActionsConfiguration(actions: [close])
    }

    /// Long-press a project: the new-session menu, so starting an agent does
    /// not require drilling in first.
    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard case .projects = sections[indexPath.section] else { return nil }
        let project = projects[indexPath.row]
        guard store.deviceEndpoint != nil, project.rosterID != nil else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(title: project.name, children: self?.store.newSessionActions(in: project) ?? [])
        }
    }
}

// MARK: - Project row

/// One project: the folder mark, the name over the branch (repos only — the
/// row collapses to one line otherwise), and a status summary trailing — the
/// most urgent state wins (attention count in orange, else a working spinner,
/// else the done dot), so a glance down the list covers every project without
/// opening one.
private struct ProjectRow: View {
    let project: MockProject
    var showsSeparator = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HugeIconShape(icon: .folder)
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let branch = project.branch {
                    Text(branch)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            summary
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        // Fill the hosting cell (see SessionRow): centers the content and
        // pins the separator to the real cell bottom.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Inset past the folder mark (10 padding + 18 icon + 10 spacing).
        .overlay(alignment: .bottom) {
            if showsSeparator { RowSeparator(leadingInset: 38) }
        }
    }

    @ViewBuilder
    private var summary: some View {
        let attention = project.sessions.count { $0.status == .needsAttention }
        let working = project.sessions.count { $0.status == .working }
        let done = project.sessions.count { $0.status == .done }
        if attention > 0 {
            HStack(spacing: 4) {
                Circle().fill(.orange).frame(width: 7, height: 7)
                Text("\(attention)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        } else if working > 0 {
            WorkingIndicator(tint: .secondary)
        } else if done > 0 {
            Circle().fill(.green).frame(width: 7, height: 7)
        }
    }
}

// MARK: - Section header

/// A small gray caps label capping a group. Mail and Files head their groups the
/// same way: the caption names what the rows under it are, and the rows say
/// nothing more about where they live.
private final class SectionCapView: UITableViewHeaderFooterView {
    static let reuseID = "sectionCap"

    private let label = UILabel()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            label.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -22),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String) {
        label.text = title.uppercased()
        isAccessibilityElement = true
        accessibilityTraits = .header
        accessibilityLabel = title
    }
}
