import SwiftUI

/// The toolbar's run capsule: the project's current task by name, which opens its
/// recent runs, beside a ▶ that runs it — a red ■ that stops it while it runs.
/// The tasks come from plugins (`PluginCommand.run`); this view only reads
/// `RunTasks` and asks the store to run or stop.
///
/// With nothing ever run in the project there is nothing to name, and the capsule
/// is a dimmed ▶ alone rather than an absence — the toolbar keeps its layout.
struct RunCapsuleToolbar: View {
    @EnvironmentObject var store: FyoloStore
    @ObservedObject var runTasks: RunTasks

    @Environment(\.controlActiveState) private var controlActive

    private static let height = InspectorTabsToolbar.controlHeight
    /// A long script name truncates rather than pushing the toolbar into overflow.
    private static let maximumNameWidth: CGFloat = 160

    private var root: String? { store.runCapsuleRoot }
    private var current: RunHistory.Record? { runTasks.selectedRecord(in: root) }

    var body: some View {
        HStack(spacing: 0) {
            if let current, let root {
                taskMenu(current.task, root: root)
            }
            runButton
        }
        .frame(height: Self.height)
        .background { if current != nil { ToolbarCapsuleChrome() } }
        .fixedSize()
    }

    private func taskMenu(_ task: RunTask, root: String) -> some View {
        Menu {
            ForEach(runTasks.recents(in: root), id: \.task.id) { record in
                Toggle(isOn: Binding(
                    get: { record.task.id == task.id },
                    set: { _ in runTasks.select(record.task, in: root) }
                )) {
                    Text(record.task.name)
                    Text(runTasks.isRunning(record.task)
                         ? localized("Running · \(record.task.command)")
                         : record.task.command)
                }
            }
            Divider()
            Button(localized("Clear Recent Runs")) { runTasks.clear(in: root) }
        } label: {
            HStack(spacing: 5) {
                Text(task.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: Self.maximumNameWidth, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(controlActive == .inactive
                             ? Color(nsColor: .disabledControlTextColor) : .primary)
            .padding(.leading, 14)
            .padding(.trailing, 2)
            .frame(height: Self.height)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(localized("Recent runs"))
    }

    private var runButton: some View {
        let task = current?.task
        let running = task.map(runTasks.isRunning) ?? false
        return Button {
            guard let task else { return }
            if running { store.stopTask(task) } else { store.runTask(task) }
        } label: {
            Image(systemName: running ? "stop.fill" : "play.fill")
                .font(.system(size: 13))
                .foregroundStyle(task == nil
                                 ? Color(nsColor: .disabledControlTextColor)
                                 : running ? Color(nsColor: .systemRed) : Color(nsColor: .systemGreen))
                .frame(width: Self.height, height: Self.height)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(task == nil)
        .help(task.map { running ? localized("Stop \($0.command)") : localized("Run \($0.command)") }
              ?? localized("Run a script from a package.json, a Makefile or a shell file to see it here"))
        .accessibilityLabel(running ? localized("Stop") : localized("Run"))
    }
}

/// The glass capsule behind the toolbar's trailing chips — the run capsule and the
/// CI chip beside it — so the two read as one family.
struct ToolbarCapsuleChrome: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: .capsule)
        } else {
            Capsule(style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.white)
        }
    }
}
