import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Plugin

/// The Monitoring pane, as a plugin: the inspector's siren segment, and the
/// incident watcher, exist only while this is switched on in Settings ▸ Plugins.
struct MonitoringPlugin: FyoloPlugin {
    static let id = "monitoring"

    var id: String { Self.id }
    var name: String { localized("Monitoring") }
    var summary: String {
        localized("Shows logs, metrics and incidents from New Relic in the inspector, filtered down to what you care about.")
    }
}

// MARK: - Pane

/// The inspector's Monitoring pane: Observability, Metrics and Incidents, each
/// a column of panels from the chosen profile, every item sifted by the
/// profile's rules and the person's own. Read only — it links out to the
/// backend for anything more.
struct MonitoringView: View {
    @EnvironmentObject var store: FyoloStore
    @StateObject private var model: MonitoringPanelModel
    @State private var ruleDraft: MonitorRuleDraft?
    @State private var queryDraft: MonitorQueryDraft?
    @State private var showsRules = false
    @State private var showsConnect = false

    /// How often the visible tab is revalidated. Each panel's own `refresh`
    /// still decides whether it is due.
    private static let pollInterval: Duration = .seconds(15)

    init(projectRoot: String?) {
        _model = StateObject(wrappedValue: MonitoringPanelModel(projectRoot: projectRoot))
    }

    var body: some View {
        Group {
            if let detail = model.detail {
                MonitorDetailView(detail: detail, model: model, ruleDraft: $ruleDraft)
            } else {
                switch model.phase {
                case .loading:
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .disconnected:
                    MonitoringConnectView(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .ready:
                    readyPane
                }
            }
        }
        .paneSettled(model.phase != .loading)
        .task(id: model.projectRoot) {
            await model.start()
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                if store.inspectorVisible, NSApp.isActive { await model.refresh(force: false) }
            }
        }
        .onChange(of: model.tab) { _, _ in Task { await model.refresh(force: false) } }
        .sheet(item: $ruleDraft) { draft in
            MonitorRuleSheet(model: model, draft: draft)
        }
        .sheet(item: $queryDraft) { draft in
            MonitorQuerySheet(model: model, draft: draft)
        }
        .sheet(isPresented: $showsRules) {
            MonitorRulesSheet(model: model)
        }
        .sheet(isPresented: $showsConnect) {
            MonitoringConnectView(model: model, onDone: { showsConnect = false })
                .padding(24)
                .frame(width: 360)
        }
    }

    private var readyPane: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 6) {
                tabSwitch
                Spacer(minLength: 0)
                variablePills
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            notices
            Divider().opacity(0.5)
            tabContent
        }
    }

    // MARK: Header

    private var topBar: some View {
        HStack(spacing: 2) {
            profileMenu
            Spacer(minLength: 0)
            filterField
            TreeHeaderButton(codicon: .refresh, help: localized("Refresh")) {
                Task { await model.refresh(force: true) }
            }
            moreMenu
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(height: GitChangesView.topBarHeight)
    }

    private var profileMenu: some View {
        Menu {
            Picker(localized("Profile"), selection: Binding(get: { model.choice }, set: { model.choose($0) })) {
                Text(localized("Everything")).tag(MonitorProfileChoice.builtIn)
                if let repository = model.repositoryProfile {
                    Text(localized("\(repository.name) (from this repository)")).tag(MonitorProfileChoice.repository)
                }
                ForEach(model.libraryProfiles) { profile in
                    Text(profile.name).tag(MonitorProfileChoice.library(profile.id))
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button(localized("Import Profile…"), action: importProfile)
            Button(localized("Export Profile…")) { exportProfile(includingMine: true) }
            Button(localized("Export Without My Changes…")) { exportProfile(includingMine: false) }
            if model.projectRoot != nil {
                Button(localized("Share to Repository")) { model.shareToRepository() }
                    .help(localized("Writes \(MonitoringLibrary.repositoryPath) so the team gets this profile with the code."))
            }
            if let url = model.profileFileURL() {
                Button(localized("Edit Profile File")) { NSWorkspace.shared.open(url) }
            }
            if case .library = model.choice {
                Divider()
                Button(localized("Delete Profile"), role: .destructive) { model.deleteCurrentProfile() }
            }
        } label: {
            Text(model.profile.name.isEmpty ? localized("Monitoring") : model.profile.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 6)
        .help(localized("Choose, import or share a Monitoring profile"))
    }

    private var moreMenu: some View {
        Menu {
            Button(localized("Add Panel…")) {
                queryDraft = MonitorQueryDraft(panel: nil, tab: model.tab, source: model.profile.connectors.first?.ref)
            }
            Button(localized("Rules…")) { showsRules = true }
            Toggle(localized("Show Hidden Panels"), isOn: $model.showsHiddenPanels)
            Divider()
            ForEach(model.connections) { connection in
                Button(localized("Disconnect \(connection.title)")) { model.disconnect(connection) }
            }
            Button(localized("Connect Another Account…")) { showsConnect = true }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(localized("Panels, rules and accounts"))
    }

    private var filterField: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(localized("Filter"), text: $model.filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .onExitCommand { model.filterText = "" }
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .frame(minWidth: 56, maxWidth: 120)
        .background { CapsuleFieldChrome() }
        .padding(.trailing, 4)
    }

    private var tabSwitch: some View {
        let open = model.openIncidentCount
        return CapsuleSwitch(
            segments: [
                (MonitorTab.observability.title, MonitorTab.observability),
                (MonitorTab.metrics.title, .metrics),
                (open > 0 ? "\(MonitorTab.incidents.title) \(open)" : MonitorTab.incidents.title, .incidents),
            ],
            selection: $model.tab)
    }

    private var variablePills: some View {
        HStack(spacing: 4) {
            ForEach(model.profile.variables.filter { !$0.options.isEmpty }) { variable in
                Menu {
                    ForEach(variable.options, id: \.self) { option in
                        Button(option) { model.setValue(option, for: variable.name) }
                    }
                } label: {
                    Text(model.values[variable.name] ?? variable.defaultValue)
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .help(variable.title ?? variable.name)
            }
            if model.isLoading {
                ProgressView().controlSize(.mini)
            }
        }
    }

    @ViewBuilder
    private var notices: some View {
        if !model.missingConnectors.isEmpty {
            MonitorNotice(
                text: localized("This profile reads \(model.missingConnectors.map(Self.describe).joined(separator: ", ")), which isn’t connected."),
                tint: .orange, actionTitle: localized("Connect…"), action: { showsConnect = true }, dismiss: nil)
        }
        if let error = model.repositoryError {
            MonitorNotice(
                text: localized("The repository’s \(MonitoringLibrary.repositoryPath) can’t be read: \(error)"),
                tint: .orange, actionTitle: nil, action: nil, dismiss: nil)
        }
        if let message = model.message {
            MonitorNotice(text: message, tint: .accentColor, actionTitle: nil, action: nil) { model.message = nil }
        }
        if model.choice == .builtIn, model.overlay.dismissedNoiseHint != true, model.results.count > 2 {
            MonitorNotice(
                text: localized("Showing everything. Right-click anything that isn’t yours and choose Hide Similar."),
                tint: .secondary, actionTitle: nil, action: nil) { model.dismissNoiseHint() }
        }
    }

    private static func describe(_ requirement: MonitorConnectorRequirement) -> String {
        if let account = requirement.accountID { return "\(requirement.type.title) \(account)" }
        return requirement.type.title
    }

    // MARK: Content

    @ViewBuilder
    private var tabContent: some View {
        let placed = model.placedPanels(model.tab)
        let visible = placed.filter { !$0.isHidden }
        let hidden = placed.filter(\.isHidden)
        if placed.isEmpty {
            PaneEmptyState(
                localized("No Panels"), icon: .siren,
                message: localized("Add a panel from the … menu, or import a profile."))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.tab == .incidents, visible.contains(where: { $0.panel.kind == .incidents }) {
                        MonitorIncidentFeed(model: model, ruleDraft: $ruleDraft)
                    }
                    ForEach(visible.filter { !(model.tab == .incidents && $0.panel.kind == .incidents) }) { placed in
                        MonitorPanelSection(model: model, placed: placed, ruleDraft: $ruleDraft, queryDraft: $queryDraft)
                    }
                    if !hidden.isEmpty {
                        hiddenPanels(hidden)
                    }
                }
                .padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder
    private func hiddenPanels(_ hidden: [MonitorPlacedPanel]) -> some View {
        if model.showsHiddenPanels {
            MonitorSectionHeader(title: localized("Hidden Panels"))
            ForEach(hidden) { placed in
                HStack {
                    Text(placed.panel.title).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(localized("Show")) { model.setHidden(false, panel: placed.id) }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 3)
            }
        } else {
            Button(localized("\(hidden.count) hidden panels")) { model.showsHiddenPanels = true }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.top, 10)
        }
    }

    // MARK: Sharing

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = localized("Choose a Monitoring profile to add")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.importProfile(from: url)
    }

    private func exportProfile(includingMine: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = MonitoringLibrary.fileName(model.profile.id)
        panel.message = includingMine
            ? localized("The profile with your panel arrangement and rules. API keys are never included.")
            : localized("The profile as it was shared, without your changes. API keys are never included.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.export(to: url, includingMine: includingMine)
    }
}

// MARK: - Panels

/// One panel: a collapsible header with its menu, the panel's items, and a
/// footer that owns up to what the rules hid.
private struct MonitorPanelSection: View {
    @ObservedObject var model: MonitoringPanelModel
    let placed: MonitorPlacedPanel
    @Binding var ruleDraft: MonitorRuleDraft?
    @Binding var queryDraft: MonitorQueryDraft?

    private var panel: MonitorPanel { placed.panel }
    private var result: MonitorPanelResult? { model.results[panel.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !placed.isCollapsed {
                content
            }
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Button {
                model.setCollapsed(!placed.isCollapsed, panel: panel.id)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(placed.isCollapsed ? 0 : 90))
                        .foregroundStyle(.tertiary)
                    Text(panel.title.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if placed.isPinned {
                        Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let error = result?.error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .help(error)
            }
            Spacer(minLength: 4)
            Menu {
                Button(placed.isPinned ? localized("Unpin") : localized("Pin to Top")) {
                    model.setPinned(!placed.isPinned, panel: panel.id)
                }
                Button(localized("Move Up")) { model.move(panel.id, by: -1, in: model.tab) }
                Button(localized("Move Down")) { model.move(panel.id, by: 1, in: model.tab) }
                Button(localized("Hide Panel")) { model.setHidden(true, panel: panel.id) }
                Divider()
                if panel.query != nil {
                    Button(localized("Edit Query…")) {
                        queryDraft = MonitorQueryDraft(panel: panel, tab: model.tab, source: panel.source)
                    }
                    Button(localized("Copy Query")) { copy(panel.query ?? "") }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 14)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var content: some View {
        switch result?.content {
        case nil:
            if let error = result?.error {
                MonitorPanelMessage(text: error, isError: true)
            } else {
                MonitorPanelMessage(text: localized("Loading…"), isError: false)
            }
        case .table(let table)?:
            if panel.kind == .stat {
                MonitorStatView(panel: panel, table: table)
            } else {
                MonitorTableView(model: model, panel: panel, table: table, ruleDraft: $ruleDraft)
            }
        case .events(let events)?:
            if panel.group == true {
                MonitorEventGroupsView(model: model, panel: panel, events: events, ruleDraft: $ruleDraft)
            } else {
                MonitorEventsView(model: model, panel: panel, events: events, ruleDraft: $ruleDraft)
            }
        case .services(let services)?:
            MonitorServicesView(model: model, panel: panel, services: services, ruleDraft: $ruleDraft)
        case .checks(let checks)?:
            MonitorChecksView(model: model, checks: checks)
        case .incidents?:
            // Merged into the Incidents feed; a panel of them anywhere else reads the same way.
            MonitorIncidentFeed(model: model, ruleDraft: $ruleDraft)
        }
    }
}

/// The rows a sifting shows — grouped items under their heading — and the
/// "N hidden" line that brings back what the rules hid.
private struct MonitorSiftedList<Item, Row: View>: View {
    @ObservedObject var model: MonitoringPanelModel
    let panelID: String
    let sifting: MonitorSifting<Item>
    let emptyText: String
    @ViewBuilder let row: (MonitorSifted<Item>, Bool) -> Row

    /// Enough rows to read at a glance; the rest are a click away.
    private static var pageSize: Int { 30 }
    @State private var showsAll = false

    var body: some View {
        let revealed = model.revealedPanels.contains(panelID)
        let shown = showsAll ? sifting.shown : Array(sifting.shown.prefix(Self.pageSize))
        VStack(alignment: .leading, spacing: 0) {
            if sifting.shown.isEmpty, sifting.hidden.isEmpty || !revealed {
                MonitorPanelMessage(text: model.filterText.isEmpty ? emptyText : localized("No matches."), isError: false)
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, sifted in
                let group = sifted.verdict.group
                if let group, index == 0 || shown[index - 1].verdict.group != group {
                    Text(group)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                }
                row(sifted, false)
            }
            if !showsAll, sifting.shown.count > Self.pageSize {
                Button(localized("Show \(sifting.shown.count - Self.pageSize) more")) { showsAll = true }
                    .buttonStyle(.link)
                    .controlSize(.small)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 3)
            }
            if revealed {
                ForEach(sifting.hidden) { sifted in
                    row(sifted, true).opacity(0.45)
                }
            }
            if !sifting.hidden.isEmpty {
                Button {
                    if revealed { model.revealedPanels.remove(panelID) } else { model.revealedPanels.insert(panelID) }
                } label: {
                    Text(revealed
                         ? localized("Hide the \(sifting.hidden.count) hidden by rules")
                         : localized("\(sifting.hidden.count) hidden by rules"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.top, 3)
            }
        }
    }
}

// MARK: Stat

private struct MonitorStatView: View {
    let panel: MonitorPanel
    let table: MonitorTable

    var body: some View {
        let row = table.rows.first ?? MonitorRow(facets: [], values: [:])
        let columns = panel.columns ?? row.fields.filter { row.number($0) != nil }.map { MonitorColumn(field: $0) }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(columns, id: \.field) { column in
                let number = row.number(column.field)
                VStack(alignment: .leading, spacing: 1) {
                    Text(column.displayTitle)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(column.format == .text ? (row.text(column.field) ?? "–") : (column.format ?? .number).string(number))
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(MonitorStyle.color(column.level(of: number)))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
    }
}

// MARK: Table

private struct MonitorTableView: View {
    @ObservedObject var model: MonitoringPanelModel
    let panel: MonitorPanel
    let table: MonitorTable
    @Binding var ruleDraft: MonitorRuleDraft?
    @State private var sortField: String?

    private var columns: [MonitorColumn] {
        if let columns = panel.columns, !columns.isEmpty { return columns }
        let sample = table.rows.first?.fields ?? []
        let numeric = sample.filter { field in table.rows.first?.number(field) != nil }
        return (sample.contains("facet") ? [MonitorColumn(field: "facet")] : [])
            + numeric.prefix(4).map { MonitorColumn(field: $0, format: .number) }
    }

    var body: some View {
        let columns = columns
        let nameColumn = columns.first { $0.field == "facet" } ?? columns.first
        let figures = columns.filter { $0.field != nameColumn?.field }
        let sort = sortField ?? panel.sort
        let rows = sort.map { field in
            table.rows.sorted { ($0.number(field) ?? -.infinity) > ($1.number(field) ?? -.infinity) }
        } ?? table.rows
        let sifting = model.sift(rows) {
            Monitoring.subject($0, table: table, tab: model.tab, panel: panel.id, source: panel.source)
        }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(nameColumn?.displayTitle ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(figures, id: \.field) { column in
                    Button { sortField = column.field } label: {
                        Text(column.displayTitle)
                            .foregroundStyle(sort == column.field ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    }
                    .buttonStyle(.plain)
                    .frame(width: 58, alignment: .trailing)
                }
            }
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 14)
            .padding(.bottom, 2)
            MonitorSiftedList(model: model, panelID: panel.id, sifting: sifting, emptyText: localized("No rows in this window.")) { sifted, _ in
                MonitorRowChrome(
                    action: { model.detail = .row(sifted.item, panel: panel) },
                    menu: { MonitorItemMenu(model: model, subject: sifted.subject, ruleDraft: $ruleDraft, link: nil) }
                ) {
                    HStack(spacing: 6) {
                        pinMark(sifted)
                        Text(nameColumn.flatMap { sifted.item.text($0.field) } ?? "–")
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(figures, id: \.field) { column in
                            let number = sifted.item.number(column.field)
                            Text(column.format == .text ? (sifted.item.text(column.field) ?? "–") : (column.format ?? .number).string(number))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(MonitorStyle.color(column.level(of: number)))
                                .lineLimit(1)
                                .frame(width: 58, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func pinMark(_ sifted: MonitorSifted<MonitorRow>) -> some View {
        if sifted.verdict.placement == .pinned {
            Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.tertiary)
        }
    }
}

// MARK: Events

private struct MonitorEventGroupsView: View {
    @ObservedObject var model: MonitoringPanelModel
    let panel: MonitorPanel
    let events: [MonitorEvent]
    @Binding var ruleDraft: MonitorRuleDraft?

    var body: some View {
        let groups = MonitorEventGroup.grouping(events)
        let sifting = model.sift(groups) { Monitoring.subject($0, tab: model.tab, panel: panel.id) }
        MonitorSiftedList(model: model, panelID: panel.id, sifting: sifting, emptyText: localized("Nothing in this window.")) { sifted, _ in
            let group = sifted.item
            MonitorRowChrome(
                action: { model.detail = .group(group, panel: panel.id) },
                menu: { MonitorItemMenu(model: model, subject: sifted.subject, ruleDraft: $ruleDraft, link: nil) }
            ) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    MonitorSeverityBar(severity: group.severity)
                    Text(MonitorFormat.compact(Double(group.count)))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .frame(minWidth: 26, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.latest.message)
                            .font(.system(size: 11.5))
                            .lineLimit(2)
                            .truncationMode(.tail)
                        Text([group.latest.service, group.lastSeen.map(MonitorStyle.ago)].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if sifted.verdict.placement == .pinned {
                        Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

private struct MonitorEventsView: View {
    @ObservedObject var model: MonitoringPanelModel
    let panel: MonitorPanel
    let events: [MonitorEvent]
    @Binding var ruleDraft: MonitorRuleDraft?

    var body: some View {
        let sifting = model.sift(events) { Monitoring.subject($0, tab: model.tab, panel: panel.id) }
        MonitorSiftedList(model: model, panelID: panel.id, sifting: sifting, emptyText: localized("Nothing in this window.")) { sifted, _ in
            let event = sifted.item
            MonitorRowChrome(
                action: { model.detail = .event(event, panel: panel.id) },
                menu: { MonitorItemMenu(model: model, subject: sifted.subject, ruleDraft: $ruleDraft, link: nil) }
            ) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    MonitorSeverityBar(severity: event.severity)
                    Text(event.time.map(MonitorStyle.clock) ?? "")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Text(event.message)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: Services

private struct MonitorServicesView: View {
    @ObservedObject var model: MonitoringPanelModel
    let panel: MonitorPanel
    let services: [MonitorService]
    @Binding var ruleDraft: MonitorRuleDraft?

    var body: some View {
        let sifting = model.sift(services) { Monitoring.subject($0, tab: model.tab, panel: panel.id) }
        MonitorSiftedList(model: model, panelID: panel.id, sifting: sifting, emptyText: localized("No services found.")) { sifted, _ in
            let service = sifted.item
            MonitorRowChrome(
                action: { model.detail = .service(service) },
                menu: { MonitorItemMenu(model: model, subject: sifted.subject, ruleDraft: $ruleDraft, link: service.link) }
            ) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(MonitorStyle.color(service.health))
                        .frame(width: 7, height: 7)
                    Text(service.name)
                        .font(.system(size: 11.5))
                        .foregroundStyle(service.isReporting ? .primary : .tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let throughput = service.values["throughput"] {
                        Text("\(MonitorFormat.compact(throughput))/m")
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let responseTime = service.values["responseTime"] {
                        Text(MonitorFormat.seconds.string(responseTime))
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .trailing)
                    }
                }
            }
        }
    }
}

// MARK: Checks

private struct MonitorChecksView: View {
    @ObservedObject var model: MonitoringPanelModel
    let checks: [MonitorCheckResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(checks) { result in
                MonitorRowChrome(action: { model.detail = .check(result) }, menu: { EmptyView() }) {
                    HStack(spacing: 7) {
                        Text(MonitorStyle.label(result.level))
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(MonitorStyle.color(result.level))
                            .frame(width: 34, alignment: .leading)
                        Text(result.check.name)
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(result.error == nil ? (result.check.format ?? .number).string(result.value) : localized("error"))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(MonitorStyle.color(result.level))
                    }
                }
            }
        }
    }
}

// MARK: Incidents

/// Every visible incident panel's incidents as one list, worst and newest first.
private struct MonitorIncidentFeed: View {
    @ObservedObject var model: MonitoringPanelModel
    @Binding var ruleDraft: MonitorRuleDraft?

    var body: some View {
        let sifting = model.incidentFeed()
        let errors = model.placedPanels(.incidents)
            .filter { !$0.isHidden && $0.panel.kind == .incidents }
            .compactMap { model.results[$0.panel.id]?.error }
        VStack(alignment: .leading, spacing: 0) {
            MonitorSectionHeader(title: localized("Incidents"))
            ForEach(Array(Set(errors)).sorted(), id: \.self) { error in
                MonitorPanelMessage(text: error, isError: true)
            }
            MonitorSiftedList(model: model, panelID: "incidents-feed", sifting: sifting, emptyText: localized("No open incidents.")) { sifted, _ in
                let incident = sifted.item
                MonitorRowChrome(
                    action: { model.detail = .incident(incident) },
                    menu: { MonitorItemMenu(model: model, subject: sifted.subject, ruleDraft: $ruleDraft, link: incident.link) }
                ) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        MonitorSeverityBar(severity: incident.isOpen ? incident.priority.severity : .debug)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(incident.title)
                                .font(.system(size: 11.5, weight: incident.isOpen ? .medium : .regular))
                                .foregroundStyle(incident.isOpen ? .primary : .secondary)
                                .lineLimit(2)
                            Text(([incident.service ?? incident.policy] + [incident.openedAt.map(MonitorStyle.ago)])
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if sifted.verdict.notifies {
                            Image(systemName: "bell.fill").font(.system(size: 8)).foregroundStyle(.tertiary)
                                .help(localized("You’ll be notified about incidents like this"))
                        }
                        if !incident.isOpen {
                            Text(localized("closed")).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Shared pieces

private struct MonitorSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }
}

private struct MonitorPanelMessage: View {
    let text: String
    let isError: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 3)
    }
}

private struct MonitorNotice: View {
    let text: String
    let tint: Color
    let actionTitle: String?
    let action: (() -> Void)?
    let dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.link).controlSize(.small)
            }
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(localized("Dismiss"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.08)))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

/// The leading stripe that carries an item's severity, so a column scans by
/// color before it is read.
private struct MonitorSeverityBar: View {
    let severity: MonitorSeverity

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(MonitorStyle.color(severity))
            .frame(width: 3, height: 12)
            .help(severity.rawValue.capitalized)
    }
}

/// A clickable row with the pane's hover highlight and a context menu.
private struct MonitorRowChrome<Content: View, Menu: View>: View {
    let action: () -> Void
    @ViewBuilder let menu: () -> Menu
    @ViewBuilder let content: () -> Content
    @State private var isHovering = false

    var body: some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(SidebarRowHighlight(isSelected: false, isHovering: isHovering, chrome: nil))
            .onHover { isHovering = $0 }
            .onTapGesture(perform: action)
            .contextMenu { menu() }
    }
}

/// What every item offers on right-click: the noise controls first.
private struct MonitorItemMenu: View {
    @ObservedObject var model: MonitoringPanelModel
    let subject: MonitorSubject
    @Binding var ruleDraft: MonitorRuleDraft?
    let link: URL?

    var body: some View {
        Button(localized("Hide Similar…")) { ruleDraft = MonitorRuleDraft(subject: subject, action: .hide) }
        if subject.tab == .incidents {
            Button(localized("Notify Me About Similar…")) { ruleDraft = MonitorRuleDraft(subject: subject, action: .notify) }
        }
        Button(localized("Group Similar…")) { ruleDraft = MonitorRuleDraft(subject: subject, action: .group) }
        Button(model.isPinned(subject.fingerprint) ? localized("Unpin") : localized("Pin")) {
            model.togglePin(item: subject.fingerprint)
        }
        Divider()
        Button(localized("Copy")) { copy(subject.text) }
        if let link {
            Button(localized("Open in Browser")) { NSWorkspace.shared.open(link) }
        }
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

enum MonitorStyle {
    static func color(_ severity: MonitorSeverity) -> Color {
        switch severity {
        case .critical: return .red
        case .error: return Color(red: 0.95, green: 0.35, blue: 0.3)
        case .warning: return .orange
        case .info: return .secondary.opacity(0.5)
        case .debug, .trace: return .secondary.opacity(0.25)
        }
    }

    static func color(_ level: MonitorLevel) -> Color {
        switch level {
        case .critical: return .red
        case .warning: return .orange
        case .noData: return .secondary
        case .normal: return .green
        case .unconfigured: return .primary
        }
    }

    static func color(_ health: MonitorService.Health) -> Color {
        switch health {
        case .critical: return .red
        case .warning: return .orange
        case .healthy: return .green
        case .unknown: return .secondary.opacity(0.4)
        }
    }

    static func label(_ level: MonitorLevel) -> String {
        switch level {
        case .critical: return "CRIT"
        case .warning: return "WARN"
        case .noData: return "NO DATA"
        case .normal: return "OK"
        case .unconfigured: return "–"
        }
    }

    static func ago(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .numeric, time: .standard)
    }
}

// MARK: - Detail

/// An item pushed into the pane: everything known about it, and the same
/// noise controls as its row.
private struct MonitorDetailView: View {
    let detail: MonitorDetail
    @ObservedObject var model: MonitoringPanelModel
    @Binding var ruleDraft: MonitorRuleDraft?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { model.detail = nil } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(localized("Back"))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if let link {
                    TreeHeaderButton(huge: .squareArrowUpRight, help: localized("Open in Browser")) {
                        NSWorkspace.shared.open(link)
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: GitChangesView.topBarHeight)
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let body = bodyText {
                        Text(body)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let subject {
                        HStack(spacing: 10) {
                            Button(localized("Hide Similar…")) { ruleDraft = MonitorRuleDraft(subject: subject, action: .hide) }
                            if subject.tab == .incidents {
                                Button(localized("Notify Me…")) { ruleDraft = MonitorRuleDraft(subject: subject, action: .notify) }
                            }
                            Button(model.isPinned(subject.fingerprint) ? localized("Unpin") : localized("Pin")) {
                                model.togglePin(item: subject.fingerprint)
                            }
                        }
                        .controlSize(.small)
                    }
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                        ForEach(fields, id: \.0) { key, value in
                            GridRow {
                                Text(key)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                Text(value)
                                    .font(.system(size: 11).monospacedDigit())
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
        .onExitCommand { model.detail = nil }
    }

    private var title: String {
        switch detail {
        case .group(let group, _): return localized("\(group.count)× \(group.latest.message)")
        case .event(let event, _): return event.message
        case .incident(let incident): return incident.title
        case .row(let row, let panel): return row.text("facet") ?? panel.title
        case .service(let service): return service.name
        case .check(let result): return result.check.name
        }
    }

    private var bodyText: String? {
        switch detail {
        case .group(let group, _): return group.latest.message
        case .event(let event, _): return event.message
        case .incident(let incident): return incident.title
        case .check(let result): return result.error ?? result.check.query
        case .row, .service: return nil
        }
    }

    private var link: URL? {
        switch detail {
        case .incident(let incident): return incident.link
        case .service(let service): return service.link
        case .check(let result): return result.check.runbook.flatMap(URL.init(string:))
        default: return nil
        }
    }

    private var subject: MonitorSubject? {
        switch detail {
        case .group(let group, let panel): return Monitoring.subject(group, tab: model.tab, panel: panel)
        case .event(let event, let panel): return Monitoring.subject(event, tab: model.tab, panel: panel)
        case .incident(let incident): return Monitoring.subject(incident, panel: nil)
        case .service(let service): return Monitoring.subject(service, tab: model.tab, panel: "")
        case .row, .check: return nil
        }
    }

    private var fields: [(String, String)] {
        switch detail {
        case .group(let group, _):
            var fields = [
                (localized("Count"), "\(group.count)"),
                (localized("Level"), group.severity.rawValue),
                (localized("Service"), group.latest.service ?? "–"),
                (localized("First seen"), group.firstSeen.map(MonitorStyle.clock) ?? "–"),
                (localized("Last seen"), group.lastSeen.map(MonitorStyle.clock) ?? "–"),
                (localized("Trace"), group.latest.traceID ?? "–"),
                (localized("Sources"), group.sources.joined(separator: ", ")),
            ]
            fields += group.latest.attributes.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            return fields
        case .event(let event, _):
            return [
                (localized("Time"), event.time.map(MonitorStyle.clock) ?? "–"),
                (localized("Level"), event.severity.rawValue),
                (localized("Service"), event.service ?? "–"),
                (localized("Trace"), event.traceID ?? "–"),
            ] + event.attributes.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        case .incident(let incident):
            return [
                (localized("State"), incident.state.rawValue),
                (localized("Priority"), incident.priority.rawValue),
                (localized("Opened"), incident.openedAt.map(MonitorStyle.clock) ?? "–"),
                (localized("Closed"), incident.closedAt.map(MonitorStyle.clock) ?? "–"),
                (localized("Entity"), incident.service ?? "–"),
                (localized("Condition"), incident.condition ?? "–"),
                (localized("Policy"), incident.policy ?? "–"),
                (localized("Source"), incident.source),
            ]
        case .row(let row, _):
            return row.fields.map { field in
                let column = MonitorColumn(field: field)
                return (column.displayTitle, row.text(field) ?? "–")
            }
        case .service(let service):
            return [
                (localized("Health"), service.health.rawValue),
                (localized("Reporting"), service.isReporting ? localized("yes") : localized("no")),
            ] + service.values.sorted { $0.key < $1.key }.map { ($0.key, MonitorFormat.plain($0.value)) }
        case .check(let result):
            return [
                (localized("Status"), MonitorStyle.label(result.level)),
                (localized("Value"), (result.check.format ?? .number).string(result.value)),
                (localized("Worst facet"), result.facet ?? "–"),
                (localized("Warning"), result.check.warn.map(MonitorFormat.plain) ?? "–"),
                (localized("Critical"), result.check.crit.map(MonitorFormat.plain) ?? "–"),
            ]
        }
    }
}

// MARK: - Rule sheet

struct MonitorRuleDraft: Identifiable {
    let id = UUID()
    let subject: MonitorSubject
    let action: MonitorRule.Action
}

/// "Hide / notify / group things like this": the example text, how alike, and
/// how widely — with a live count of what the rule would catch right now, which
/// is how the slider gets calibrated.
private struct MonitorRuleSheet: View {
    @ObservedObject var model: MonitoringPanelModel
    let draft: MonitorRuleDraft
    @Environment(\.dismiss) private var dismiss

    enum Scope: Hashable { case panel, tab, everywhere }

    @State private var text = ""
    @State private var strength = 60.0
    @State private var scope: Scope = .tab
    @State private var sameService = true
    @State private var groupName = ""

    private var rule: MonitorRule {
        var match = MonitorRuleMatch(similarTo: MonitorSimilarity(text: text, strength: Int(strength)))
        switch scope {
        case .panel:
            match.tab = draft.subject.tab
            match.panel = draft.subject.panel
        case .tab:
            match.tab = draft.subject.tab
        case .everywhere:
            break
        }
        if sameService { match.service = draft.subject.service }
        return MonitorRule(
            name: String(text.prefix(60)), match: match, action: draft.action,
            group: draft.action == .group ? (groupName.isEmpty ? String(text.prefix(30)) : groupName) : nil)
    }

    var body: some View {
        let rule = rule
        let engine = MonitorRuleEngine(rules: [rule])
        let candidates = scope == .everywhere
            ? MonitorTab.allCases.flatMap { model.currentSubjects(in: $0) }
            : model.currentSubjects(in: draft.subject.tab)
        let matches = candidates.filter { engine.matches(rule, $0) }
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField(localized("Text"), text: $text, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 2) {
                Slider(value: $strength, in: 0...100, step: 5)
                HStack {
                    Text(localized("Even slightly similar"))
                    Spacer()
                    Text("\(Int(strength))")
                        .monospacedDigit()
                    Spacer()
                    Text(localized("Almost the same text"))
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            Picker(localized("Applies to"), selection: $scope) {
                if draft.subject.panel != nil { Text(localized("This panel")).tag(Scope.panel) }
                Text(draft.subject.tab.title).tag(Scope.tab)
                Text(localized("Every tab")).tag(Scope.everywhere)
            }
            .pickerStyle(.segmented)
            if let service = draft.subject.service {
                Toggle(localized("Only from \(service)"), isOn: $sameService)
            }
            if draft.action == .group {
                TextField(localized("Group name"), text: $groupName).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(localized("Matches \(matches.count) of \(candidates.count) items on screen"))
                    .font(.system(size: 11, weight: .medium))
                ForEach(Array(matches.prefix(6).enumerated()), id: \.offset) { _, subject in
                    Text(subject.text)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if matches.count > 6 {
                    Text(localized("and \(matches.count - 6) more"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
            HStack {
                Spacer()
                Button(localized("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) {
                    model.addRule(rule)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            text = draft.subject.text
            sameService = draft.subject.service != nil && draft.action != .notify
        }
    }

    private var title: String {
        switch draft.action {
        case .hide: return localized("Hide Similar")
        case .notify: return localized("Notify Me About Similar Incidents")
        case .group: return localized("Group Similar")
        default: return localized("Rule")
        }
    }

    private var confirmTitle: String {
        switch draft.action {
        case .hide: return localized("Hide")
        case .notify: return localized("Notify Me")
        case .group: return localized("Group")
        default: return localized("Add")
        }
    }
}

/// Every rule in force, in the order they run: the person's own (removable)
/// before the profile's.
private struct MonitorRulesSheet: View {
    @ObservedObject var model: MonitoringPanelModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localized("Rules")).font(.headline)
            Text(localized("Each item takes the first rule that matches it, once for where it shows and once for whether it notifies."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            List {
                Section(localized("Yours")) {
                    if model.overlay.rules.isEmpty {
                        Text(localized("None yet. Right-click an item to add one.")).foregroundStyle(.secondary)
                    }
                    ForEach(model.overlay.rules) { rule in
                        HStack {
                            ruleLabel(rule)
                            Spacer()
                            Button { model.removeRule(id: rule.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help(localized("Remove"))
                        }
                    }
                }
                Section(localized("From the profile")) {
                    if model.profile.rules.isEmpty {
                        Text(localized("None")).foregroundStyle(.secondary)
                    }
                    ForEach(model.profile.rules) { rule in ruleLabel(rule) }
                }
            }
            .frame(minHeight: 240)
            HStack {
                Spacer()
                Button(localized("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func ruleLabel(_ rule: MonitorRule) -> some View {
        var scope: [String] = []
        if let tab = rule.match.tab { scope.append(tab.title) }
        if let service = rule.match.service { scope.append(service) }
        if let similar = rule.match.similarTo { scope.append(localized("similarity \(similar.strength)")) }
        if let contains = rule.match.contains { scope.append(localized("contains “\(contains)”")) }
        return VStack(alignment: .leading, spacing: 1) {
            Text("\(rule.action.rawValue.capitalized): \(rule.name ?? rule.match.similarTo?.text ?? rule.id)")
                .lineLimit(1)
            Text(scope.joined(separator: " · "))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Query sheet

struct MonitorQueryDraft: Identifiable {
    let id = UUID()
    let panel: MonitorPanel?
    let tab: MonitorTab
    let source: String?
}

/// Edits a panel's query, or adds a panel. The query is the backend's own
/// language; `{{variables}}` fill from the header. Run shows the answer
/// before anything is saved.
private struct MonitorQuerySheet: View {
    @ObservedObject var model: MonitoringPanelModel
    let draft: MonitorQueryDraft
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var kind: MonitorPanel.Kind = .table
    @State private var query = ""
    @State private var groups = true
    @State private var preview: String?
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(draft.panel == nil ? localized("Add Panel") : localized("Edit Query")).font(.headline)
            TextField(localized("Title"), text: $title).textFieldStyle(.roundedBorder)
            if draft.panel == nil {
                Picker(localized("Shows"), selection: $kind) {
                    Text(localized("Table")).tag(MonitorPanel.Kind.table)
                    Text(localized("Numbers")).tag(MonitorPanel.Kind.stat)
                    Text(localized("Log lines")).tag(MonitorPanel.Kind.events)
                }
                .pickerStyle(.segmented)
                if kind == .events {
                    Toggle(localized("Group lines that say the same thing"), isOn: $groups)
                }
            }
            TextEditor(text: $query)
                .font(.system(size: 11.5, design: .monospaced))
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15)))
            Text(localized("NRQL. Use {{\(model.profile.variables.map(\.name).joined(separator: "}}, {{"))}} for the header’s values."))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            if let preview {
                ScrollView {
                    Text(preview)
                        .font(.system(size: 10.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
            HStack {
                Button(localized("Run")) { Task { await run() } }
                    .disabled(isRunning || query.isEmpty)
                if isRunning { ProgressView().controlSize(.small) }
                Spacer()
                Button(localized("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(localized("Save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(query.isEmpty || title.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            title = draft.panel?.title ?? ""
            query = draft.panel?.query ?? ""
            kind = draft.panel?.kind ?? .table
        }
    }

    private func run() async {
        isRunning = true
        defer { isRunning = false }
        let probe = MonitorPanel(id: "preview", title: title, kind: kind, source: draft.source, query: query)
        guard let resolved = Monitoring.connection(for: probe, in: model.profile, connections: model.connections) else {
            preview = MonitorPanelError.noConnection(draft.source ?? "").localizedDescription
            return
        }
        do {
            let rendered = try MonitorQueryTemplate.render(query, variables: model.profile.variables, values: model.values)
            let source = NewRelicSource(connection: resolved.connection, ref: resolved.ref)
            guard let result = await source.run([rendered]).first else { return }
            if let error = result.error {
                preview = error
            } else {
                let rows = result.table.rows.prefix(8).map { row in
                    row.fields.map { "\($0)=\(row.text($0) ?? "–")" }.joined(separator: "  ")
                }
                preview = localized("\(result.table.rows.count) rows") + "\n" + rows.joined(separator: "\n")
            }
        } catch {
            preview = error.localizedDescription
        }
    }

    private func save() {
        if let panel = draft.panel {
            model.editProfile { profile in
                for tab in MonitorTab.allCases {
                    var panels = profile.panels(in: tab)
                    guard let index = panels.firstIndex(where: { $0.id == panel.id }) else { continue }
                    panels[index].query = query
                    panels[index].title = title
                    profile.setPanels(panels, in: tab)
                }
            }
        } else {
            let id = "panel-\(UUID().uuidString.prefix(8).lowercased())"
            let panel = MonitorPanel(
                id: id, title: title, kind: kind, source: draft.source, query: query,
                group: kind == .events ? groups : nil)
            model.editProfile { profile in
                profile.setPanels(profile.panels(in: draft.tab) + [panel], in: draft.tab)
            }
        }
        dismiss()
    }
}

// MARK: - Connect

/// Connect a New Relic account with a User key. A key that reads several
/// accounts asks which one; the key is kept in the Keychain.
struct MonitoringConnectView: View {
    @ObservedObject var model: MonitoringPanelModel
    var onDone: (() -> Void)?
    @State private var apiKey = ""
    @State private var region: NewRelicRegion = .us

    var body: some View {
        GitHubPrompt(
            title: localized("Monitoring"),
            message: localized("Connect New Relic to see your services’ logs, metrics and incidents here. More backends will follow."),
            errorMessage: model.connectError,
            icon: .siren
        ) {
            VStack(spacing: 8) {
                if model.pendingAccounts.isEmpty {
                    SecureField(localized("New Relic User key (NRAK-…)"), text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                        .onSubmit { Task { await model.check(apiKey: apiKey, region: region) } }
                    Picker(localized("Region"), selection: $region) {
                        ForEach(NewRelicRegion.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 140)
                    .labelsHidden()
                    HStack(spacing: 10) {
                        Button {
                            Task { await model.check(apiKey: apiKey, region: region) }
                        } label: {
                            if model.isConnecting { ProgressView().controlSize(.small) } else { Text(localized("Connect")) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isConnecting || apiKey.isEmpty)
                        if let url = MonitoringAuth.newRelicKeyURL {
                            Link(localized("Create a Key…"), destination: url).font(.system(size: 11))
                        }
                    }
                    if let onDone {
                        Button(localized("Cancel")) {
                            model.cancelConnecting()
                            onDone()
                        }
                        .buttonStyle(.link)
                        .controlSize(.small)
                    }
                } else {
                    Text(localized("Which account?")).font(.system(size: 11, weight: .medium))
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(model.pendingAccounts) { account in
                                Button {
                                    model.connect(account: account)
                                    onDone?()
                                } label: {
                                    HStack {
                                        Text(account.name)
                                        Spacer()
                                        Text(String(account.id))
                                            .foregroundStyle(.secondary)
                                            .font(.system(size: 11, design: .monospaced))
                                    }
                                    .frame(maxWidth: 240)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    Button(localized("Cancel")) { model.cancelConnecting() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            }
        }
        .onChange(of: model.connections.count) { _, _ in
            if model.pendingAccounts.isEmpty { onDone?() }
        }
    }
}
