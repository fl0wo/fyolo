import AppKit
import SwiftUI

// MARK: - Pane model

/// The Docker pane's list: this Mac's running containers, re-read on a short
/// interval while the pane is on screen.
@MainActor
final class DockerPanelModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case unavailable(String)
        case loaded([DockerContainer])
    }

    @Published private(set) var phase: Phase = .loading

    func refresh() async {
        do {
            let containers = try await DockerService.runningContainers()
            if phase != .loaded(containers) { phase = .loaded(containers) }
        } catch {
            let message = error.localizedDescription
            if phase != .unavailable(message) { phase = .unavailable(message) }
        }
    }
}

// MARK: - Pane

/// The inspector's Docker pane: the containers running on this Mac, grouped by
/// Compose project, each opening onto its logs and its inspect details. Read-only
/// on purpose — starting, stopping and removing stay in the terminal.
struct DockerView: View {
    @EnvironmentObject var store: FyoloStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var model = DockerPanelModel()
    @State private var openContainer: DockerContainer?

    /// Often enough that a container started from the terminal shows up while
    /// you look; `docker ps` is cheap at this rate, and it only runs while the
    /// pane is visible.
    private static let refreshInterval: Duration = .seconds(3)

    var body: some View {
        Group {
            if let openContainer {
                DockerContainerDetailView(container: openContainer) { self.openContainer = nil }
                    .id(openContainer.id)
            } else {
                listPane
            }
        }
        // Honest from the first frame: the model starts in `.loading`.
        .paneSettled()
        .task {
            while !Task.isCancelled {
                if store.inspectorVisible { await model.refresh() }
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    @ViewBuilder
    private var listPane: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable(let message):
            PaneEmptyState(localized("Docker"), icon: .docker, message: message)
        case .loaded(let containers) where containers.isEmpty:
            PaneEmptyState(
                localized("No Running Containers"),
                icon: .docker,
                message: localized("Containers you start appear here.")
            )
        case .loaded(let containers):
            list(containers)
        }
    }

    private func list(_ containers: [DockerContainer]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Self.groups(containers), id: \.title) { group in
                    Text(group.title.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                    ForEach(group.containers) { container in
                        DockerContainerRow(
                            container: container,
                            font: settings.interfaceFont,
                            chrome: settings.chromeTheme(for: colorScheme)
                        ) { openContainer = container }
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.automatic)
    }

    /// Compose projects first, alphabetically, each holding its services; any
    /// container Compose didn't start goes in one trailing group.
    static func groups(_ containers: [DockerContainer]) -> [(title: String, containers: [DockerContainer])] {
        let byProject = Dictionary(grouping: containers) { $0.composeProject }
        var groups = byProject.compactMap { project, members -> (String, [DockerContainer])? in
            guard let project else { return nil }
            return (project, members.sorted { $0.name < $1.name })
        }
        .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
        if let loose = byProject[nil], !loose.isEmpty {
            groups.append((localized("Containers"), loose))
        }
        return groups.map { (title: $0.0, containers: $0.1) }
    }
}

/// One container: a health-tinted dot, the name over its image, and how long it
/// has been up. Lifted on hover with the sidebar's own highlight.
private struct DockerContainerRow: View {
    let container: DockerContainer
    let font: Font
    let chrome: ChromeTheme?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Circle()
                    .fill(DockerStatusDot.color(for: container.health))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(container.composeService ?? container.name)
                        .font(font)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(container.image)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                Text(DockerStatusDot.uptime(container.status))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SidebarRowHighlight(isSelected: false, isHovering: isHovering, chrome: chrome))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(container.status)
    }
}

/// The status vocabulary the list and the detail share.
enum DockerStatusDot {
    static func color(for health: DockerContainer.Health) -> Color {
        switch health {
        case .healthy, .none: .green
        case .starting: .orange
        case .unhealthy: .red
        }
    }

    /// "Up 3 hours (healthy)" → "3 hours": the row already shows health as color.
    static func uptime(_ status: String) -> String {
        var text = status
        if text.hasPrefix("Up ") { text.removeFirst(3) }
        if let paren = text.firstIndex(of: "(") { text = String(text[..<paren]) }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Detail

/// One container's logs and inspect details, pushed over the list.
@MainActor
final class DockerContainerModel: ObservableObject {
    let id: String
    @Published private(set) var logs = ""
    @Published private(set) var logsError: String?
    @Published private(set) var details: DockerContainerDetails?
    @Published private(set) var detailsError: String?

    /// How far back the Logs view reaches; enough to see what led up to now
    /// without reading a long-lived service's whole history.
    static let logTail = 500

    init(id: String) {
        self.id = id
    }

    func loadLogs() async {
        do {
            let text = try await DockerService.logs(of: id, tail: Self.logTail)
            if text != logs { logs = text }
            logsError = nil
        } catch {
            logsError = error.localizedDescription
        }
    }

    func loadDetails() async {
        do {
            details = try await DockerService.details(of: id)
            detailsError = nil
        } catch {
            detailsError = error.localizedDescription
        }
    }
}

private enum DockerDetailTab: Hashable { case logs, info }

private struct DockerContainerDetailView: View {
    let container: DockerContainer
    let onBack: () -> Void
    @StateObject private var model: DockerContainerModel
    @State private var tab: DockerDetailTab = .logs
    @State private var isFollowing = true

    private static let followInterval: Duration = .seconds(2)

    init(container: DockerContainer, onBack: @escaping () -> Void) {
        self.container = container
        self.onBack = onBack
        _model = StateObject(wrappedValue: DockerContainerModel(id: container.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            switch tab {
            case .logs: logsPane
            case .info: infoPane
            }
        }
        .task { await model.loadDetails() }
        .task(id: isFollowing) {
            await model.loadLogs()
            while isFollowing, !Task.isCancelled {
                try? await Task.sleep(for: Self.followInterval)
                await model.loadLogs()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(localized("All Containers"))
                Circle()
                    .fill(DockerStatusDot.color(for: container.health))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(container.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(container.image)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            HStack {
                CapsuleSwitch(
                    segments: [(localized("Logs"), .logs), (localized("Info"), .info)],
                    selection: $tab)
                Spacer()
                if tab == .logs {
                    Toggle(localized("Follow"), isOn: $isFollowing)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: Logs

    private var logsPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let error = model.logsError {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .padding(.bottom, 6)
                    }
                    Text(model.logs.isEmpty && model.logsError == nil
                         ? localized("No output yet.") : model.logs)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(model.logs.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(10)
            }
            .onChange(of: model.logs) {
                if isFollowing { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
        }
    }

    private static let bottomAnchor = "bottom"

    // MARK: Info

    @ViewBuilder
    private var infoPane: some View {
        if let details = model.details {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DockerInfoSection(title: localized("Container")) {
                        DockerInfoRow(label: localized("Status"), value: status(details))
                        if let started = details.startedAt {
                            DockerInfoRow(
                                label: localized("Started"),
                                value: started.formatted(date: .abbreviated, time: .shortened))
                        }
                        DockerInfoRow(label: localized("Image"), value: details.image)
                        if let project = details.labels["com.docker.compose.project"] {
                            let service = details.labels["com.docker.compose.service"]
                            DockerInfoRow(
                                label: localized("Compose"),
                                value: service.map { "\(project) › \($0)" } ?? project)
                        }
                        if let restart = details.restartPolicy {
                            DockerInfoRow(label: localized("Restart"), value: restart)
                        }
                        DockerInfoRow(label: "ID", value: String(details.id.prefix(12)), monospaced: true)
                    }
                    if !details.command.isEmpty || details.workingDirectory != nil {
                        DockerInfoSection(title: localized("Command")) {
                            if !details.command.isEmpty {
                                DockerInfoValue(text: details.command)
                            }
                            if let directory = details.workingDirectory {
                                DockerInfoRow(label: localized("Directory"), value: directory, monospaced: true)
                            }
                        }
                    }
                    if !details.ports.isEmpty {
                        DockerInfoSection(title: localized("Ports")) {
                            ForEach(details.ports, id: \.self) { port in
                                DockerInfoRow(
                                    label: port.container,
                                    value: port.host ?? localized("not published"),
                                    monospaced: true)
                            }
                        }
                    }
                    if !details.networks.isEmpty {
                        DockerInfoSection(title: localized("Networks")) {
                            ForEach(details.networks, id: \.self) { network in
                                DockerInfoRow(label: network.name, value: network.address ?? "—", monospaced: true)
                            }
                        }
                    }
                    if !details.mounts.isEmpty {
                        DockerInfoSection(title: localized("Mounts")) {
                            ForEach(details.mounts, id: \.self) { mount in
                                DockerInfoValue(
                                    text: "\(mount.source) → \(mount.destination)"
                                        + (mount.isReadOnly ? " (ro)" : ""))
                            }
                        }
                    }
                    if !details.environment.isEmpty {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(details.environment, id: \.self) { DockerInfoValue(text: $0) }
                            }
                            .padding(.top, 4)
                        } label: {
                            Text(localized("Environment (\(details.environment.count))").uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(12)
            }
        } else if let error = model.detailsError {
            PaneEmptyState(localized("Couldn’t Inspect"), icon: .docker, message: error)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func status(_ details: DockerContainerDetails) -> String {
        guard let health = details.health, health != "none" else { return details.state }
        return "\(details.state) · \(health)"
    }
}

private struct DockerInfoSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            content()
        }
    }
}

private struct DockerInfoRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(value)
                .font(.system(size: 11, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A full-width value with no label — a command line, a mount, an env entry.
private struct DockerInfoValue: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
