import SwiftUI
import FyoloShared
import UIKit

// MARK: - The scope

/// Which workspace the home lists are showing. Slack's shape all the way down:
/// the rail is context, the list is content, and the title names the context you
/// are in — so this is one workspace at a time, never a union of them.
///
/// App-scoped rather than owned by a screen. The rail lives in the shell above
/// the tab bar and the lists that honour it sit in different tabs, so the choice
/// has to outlive any one of them. It outlives the process too: coming back to
/// the workspace you left is the whole reason a switcher is worth having.
///
/// What this deliberately never reaches is the "Needs You" strip. That strip
/// answers the cross-workspace question the phone exists for — which agent is
/// blocked on me, anywhere — so scoping it would hide the very thing the app was
/// opened to see. It is also what makes a single-workspace list safe: nothing
/// goes unnoticed just because it is out of scope.
@MainActor
final class WorkspaceScope {
    /// Posted after the scope changes; screens re-filter on it.
    static let didChange = Notification.Name("WorkspaceScopeDidChange")

    private static let storageKey = "workspace.currentID"

    /// The Mac's workspace id in scope. nil only before the first roster of a
    /// fresh install has named one.
    private(set) var selectedID: String?

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey)
        // Empty reads as "nothing chosen", so a launch-argument override can
        // clear it and `reconcile` picks the roster's first workspace again.
        selectedID = (stored?.isEmpty ?? true) ? nil : stored
    }

    /// Does a project belong to the current scope? Everything passes while no
    /// workspace has been chosen yet, so a roster that arrives a beat ahead of
    /// `reconcile` shows a full list rather than a blank one.
    func admits(_ project: MockProject) -> Bool {
        guard let selectedID else { return true }
        return project.workspaceID == selectedID
    }

    func select(_ id: String) {
        guard id != selectedID else { return }
        selectedID = id
        UserDefaults.standard.set(id, forKey: Self.storageKey)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Keep the scope on a workspace the Mac is actually pushing: the first one
    /// in roster order on a first launch, and again when the one in scope closes
    /// or the phone switches to a Mac that never heard of it.
    ///
    /// An empty roster is left alone — a dropped socket must not spend the
    /// remembered workspace, because reconnecting is supposed to land back where
    /// the user was.
    func reconcile(against projects: [MockProject]) {
        guard let first = projects.first?.workspaceID else { return }
        if let selectedID, projects.contains(where: { $0.workspaceID == selectedID }) { return }
        select(first)
    }
}

/// A tab-bar home root that shows one workspace at a time. The rail's edge
/// gesture and its opener are offered only on screens that adopt this, so a
/// swipe never reveals a rail that would change nothing.
@MainActor
protocol WorkspaceScoped: AnyObject {}

// MARK: - The roster the rail draws

/// One rail row: a workspace the Mac has pushed at least one container for. The
/// Mac emits nothing at all for an empty workspace, so every row here has
/// something behind it.
struct RailWorkspace: Equatable {
    let id: String
    let name: String
    /// The `~/.ssh/config` alias of the machine it is on, nil for the paired Mac.
    let deviceAlias: String?

    /// The machine to name alongside this workspace, and nil when there is
    /// nothing to add: the paired Mac carries no mark — being on the machine you
    /// paired with is the absence of one — and neither does a workspace already
    /// named after its box. Both rules are the desktop sidebar's.
    var machineLabel: String? {
        guard let deviceAlias,
              deviceAlias.caseInsensitiveCompare(name) != .orderedSame
        else { return nil }
        return deviceAlias
    }
}

/// One machine's workspaces. A workspace belongs to exactly one machine, so this
/// grouping costs nothing to derive and is never ambiguous.
struct RailMachine {
    /// The `~/.ssh/config` alias, nil for the paired Mac itself.
    let alias: String?
    var workspaces: [RailWorkspace]

    /// What heads the group. The paired Mac has no alias, so it borrows the name
    /// that Mac reports, and falls back to the generic before anything has named
    /// it.
    var title: String {
        alias ?? CompanionLink.activeMac?.name ?? localized("This Mac")
    }

    /// The roster in the order the Mac pushed it: workspaces in first-appearance
    /// order, gathered under the machine they are on, machines likewise in the
    /// order their first workspace appeared. Sorting is never applied here — the
    /// desktop sidebar's order is the order, and a rail that re-shuffles under
    /// the finger is a rail nobody builds muscle memory for.
    static func roster(from projects: [MockProject]) -> [RailMachine] {
        var machines: [RailMachine] = []
        var machineIndex: [String: Int] = [:]
        var seenWorkspaces: Set<String> = []
        for project in projects where !seenWorkspaces.contains(project.workspaceID) {
            seenWorkspaces.insert(project.workspaceID)
            let workspace = RailWorkspace(
                id: project.workspaceID,
                name: project.workspaceName,
                deviceAlias: project.deviceAlias
            )
            // nil (this Mac) needs a key of its own that no alias can collide with.
            let key = project.deviceAlias.map { "alias:\($0)" } ?? "self"
            if let index = machineIndex[key] {
                machines[index].workspaces.append(workspace)
            } else {
                machineIndex[key] = machines.count
                machines.append(RailMachine(alias: project.deviceAlias, workspaces: [workspace]))
            }
        }
        return machines
    }
}

extension Array where Element == RailMachine {
    var workspaceCount: Int { reduce(0) { $0 + $1.workspaces.count } }

    func workspace(id: String?) -> RailWorkspace? {
        guard let id else { return nil }
        return lazy.flatMap(\.workspaces).first { $0.id == id }
    }
}

// MARK: - The rail

/// The workspace rail: Slack's left column on a phone. One row per workspace, in
/// the Mac's pushed order, under a machine heading once there is a second
/// machine to tell them apart. Picking one moves the whole home screen into it.
///
/// The shell owns the panel's motion and its gestures; this controller is only
/// the content. That split is what lets the swipe be interruptible — the frames
/// belong to one place.
final class WorkspaceRailViewController: UIViewController {
    private let store: RosterStore
    private let scope: WorkspaceScope

    /// Fired when a row is picked, so the shell can dismiss the rail.
    var onSelect: (() -> Void)?

    private var machines: [RailMachine] = []

    private let tableView = UITableView(frame: .zero, style: .grouped)
    private var rosterObserver: NSObjectProtocol?
    private var scopeObserver: NSObjectProtocol?
    private var themeObserver: NSObjectProtocol?

    init(store: RosterStore, scope: WorkspaceScope) {
        self.store = store
        self.scope = scope
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        for observer in [rosterObserver, scopeObserver, themeObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Opaque, and on the same themed canvas as the pages behind it: the
        // shadow and the dimming are what separate the two, not a second color.
        themeObserver = installThemeBackdrop()
        let topBar = configureTopBar()
        configureTable(below: topBar)
        reload()
        rosterObserver = NotificationCenter.default.addObserver(
            forName: RosterStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        scopeObserver = NotificationCenter.default.addObserver(
            forName: WorkspaceScope.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        machines = RailMachine.roster(from: store.projects)
        tableView.reloadData()
    }

    // MARK: - Chrome

    private func configureTopBar() -> UIView {
        let title = UILabel()
        title.text = localized("Workspaces")
        // A step down from the home screens' 34pt: the rail is narrower than a
        // page, and a title sized for a full width would truncate on this one.
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.textColor = .label
        title.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(title)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            title.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
        ])
        return title
    }

    private func configureTable(below topBar: UIView) {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.sectionHeaderTopPadding = 0
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        tableView.register(
            RailMachineHeaderView.self,
            forHeaderFooterViewReuseIdentifier: RailMachineHeaderView.reuseID
        )
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 12),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// The machine only heads its group when there is a second machine to tell it
    /// apart from — the same rule the Mac's own switcher follows, so one-machine
    /// users never see a level they don't have.
    private var showsMachineHeadings: Bool { machines.count > 1 }
}

// MARK: - Table data source / delegate

extension WorkspaceRailViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int { machines.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        machines[section].workspaces.count
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard showsMachineHeadings else { return nil }
        guard let header = tableView.dequeueReusableHeaderFooterView(
            withIdentifier: RailMachineHeaderView.reuseID
        ) as? RailMachineHeaderView else { return nil }
        header.configure(title: machines[section].title)
        return header
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        showsMachineHeadings ? 28 : 0
    }

    /// A whitespace gap under each group, like every other list in the app.
    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat { 12 }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? { UIView() }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        cell.selectionStyle = .none
        cell.backgroundColor = .clear
        let workspaces = machines[indexPath.section].workspaces
        let workspace = workspaces[indexPath.row]
        cell.contentConfiguration = UIHostingConfiguration {
            WorkspaceRailRow(
                name: workspace.name,
                isSelected: workspace.id == scope.selectedID,
                showsSeparator: indexPath.row < workspaces.count - 1
            )
        }
        .margins(.horizontal, 12)
        .margins(.vertical, 0)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        scope.select(machines[indexPath.section].workspaces[indexPath.row].id)
        onSelect?()
    }
}

// MARK: - Rows

/// One workspace. The name, and a checkmark on the one in scope — the same two
/// halves the Mac's own workspace menu draws, so the two switchers read alike.
private struct WorkspaceRailRow: View {
    let name: String
    let isSelected: Bool
    var showsSeparator = false

    var body: some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 11)
        .background(
            isSelected ? Color.primary.opacity(0.08) : .clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if showsSeparator { RowSeparator(leadingInset: 10) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The machine heading over a group of workspaces. Its case is left alone,
/// unlike the uppercased captions elsewhere: this is an `~/.ssh/config` alias, a
/// literal the user typed, and recasing it makes it something they can't find
/// again.
private final class RailMachineHeaderView: UITableViewHeaderFooterView {
    static let reuseID = "railMachine"

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
        label.text = title
        isAccessibilityElement = true
        accessibilityTraits = .header
        accessibilityLabel = title
    }
}
