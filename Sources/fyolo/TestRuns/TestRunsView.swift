import AppKit
import FyoloShared
import SwiftUI

/// The inspector's Tests pane: one test run at a time, the newest by default,
/// with a picker for the last few, whichever runner each came from. Read-only. The run says how many tests failed
/// and passed, then lists the failures by file, each opening to its message and
/// diff, with the passing files folded beneath. A live run counts up in place and
/// shows its results when it ends.
///
/// Following the newest is the default, so a run that starts while the pane is
/// open replaces the one on screen. A run picked by hand stays until it ages out
/// of the device's history.
struct TestRunsView: View {
    @EnvironmentObject var store: FyoloStore
    @ObservedObject var model: TestRunsModel
    /// The run picked by hand, or `nil` to follow the newest.
    @State private var pickedID: String?

    private var selected: Fyolod.TestRunSummary? {
        pickedID.flatMap { id in model.runs.first { $0.id == id } } ?? model.runs.first
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.5)
            if let run = selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        TestRunHeader(run: run)
                        runBody(run)
                            .padding(.leading, 34)
                            .padding(.trailing, 12)
                            .padding(.bottom, 12)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Fetched once the run is over, which is also when a followed live
                // run turns into a finished one.
                .task(id: "\(run.id)|\(run.state)") { model.loadDetail(for: run) }
            } else {
                PaneEmptyState(
                    localized("No Test Runs"), icon: .beaker,
                    message: localized("Test runs started in a fyolo terminal appear here."))
            }
        }
        .paneSettled(model.hasAnswered)
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            if let run = selected {
                TestRunnerMark(runner: run.runner)
                Text(verbatim: run.runnerName)
                    .font(.system(size: 12, weight: .semibold))
            } else {
                HugeIconView(icon: .beaker, size: 13, color: .secondary, lineWidthOverride: 1.5)
                Text(localized("Tests"))
                    .font(.system(size: 12, weight: .semibold))
            }
            Spacer(minLength: 0)
            if model.runs.count > 1 { runPicker }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: GitChangesView.topBarHeight)
    }

    /// The last runs, newest first. Picking the newest goes back to following it.
    private var runPicker: some View {
        Menu {
            Picker(localized("Run"), selection: Binding(
                get: { selected?.id ?? "" },
                set: { id in pickedID = id == model.runs.first?.id ? nil : id })
            ) {
                ForEach(model.runs) { run in
                    Label {
                        Text(run.menuTitle(now: Date()))
                    } icon: {
                        TestRunnerMark.menuImage(runner: run.runner)
                    }
                    .tag(run.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(pickedID == nil ? localized("Latest") : selected?.relativeStart(now: Date()) ?? "")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(localized("Show an earlier run"))
    }

    @ViewBuilder
    private func runBody(_ run: Fyolod.TestRunSummary) -> some View {
        if run.isRunning {
            Text(localized("Results appear when the run ends."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if let detail = model.details[run.id] {
            TestRunDetailView(detail: detail, open: open)
                .id(run.id)
        } else {
            ProgressView().controlSize(.small).padding(.vertical, 6)
        }
    }

    /// Opens `path:line`, relative to the run's root: the editor for this Mac's
    /// files, the read-only preview for a device's.
    private func open(_ location: String) {
        guard let checkout = model.checkout, let root = model.root else { return }
        var path = location
        var line: Int?
        if let colon = location.lastIndex(of: ":"), let number = Int(location[location.index(after: colon)...]) {
            path = String(location[..<colon])
            line = number
        }
        let absolute = path.hasPrefix("/") ? path : (root as NSString).appendingPathComponent(path)
        if checkout.isOnAnotherDevice {
            store.openRemoteFile(
                path: absolute, name: (absolute as NSString).lastPathComponent,
                provider: DeviceFileProvider(route: checkout.device.route, root: root),
                host: checkout.device.name, at: line)
        } else {
            store.openFileInEditor(URL(fileURLWithPath: absolute), at: line)
        }
    }
}

/// The selected run's summary: its result, then when and what ran, then the
/// shell command it came from.
private struct TestRunHeader: View {
    let run: Fyolod.TestRunSummary

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            TestRunStateIcon(state: run.state)
                .frame(width: 14, height: 14)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                countsLine
                if run.isRunning {
                    if run.filesTotal > 0 {
                        ProgressView(value: Double(run.filesDone), total: Double(run.filesTotal))
                            .progressViewStyle(.linear)
                            .controlSize(.mini)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(run.liveLine(now: context.date))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } else {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(run.finishedLine(now: context.date))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if let command = run.command {
                    Text(command)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var countsLine: some View {
        var parts: [Text] = []
        if run.counts.failed > 0 {
            parts.append(Text(localized("\(run.counts.failed) failed")).foregroundColor(.red))
        }
        parts.append(Text(localized("\(run.counts.passed) passed")))
        if run.counts.skipped > 0 {
            parts.append(Text(localized("\(run.counts.skipped) skipped")).foregroundColor(.secondary))
        }
        if run.failedWithoutFailedTests {
            parts.append(Text(localized("errors")).foregroundColor(.red))
        }
        let separator = Text(" · ").foregroundColor(.secondary)
        let line = parts.dropFirst().reduce(parts[0]) { $0 + separator + $1 }
        return line.font(.system(size: 12, weight: .medium)).lineLimit(1)
    }
}

private extension Fyolod.TestRunSummary {
    /// A file that failed to load, or an error outside any test, fails the run
    /// with no failed test to count.
    var failedWithoutFailedTests: Bool { state == "failed" && counts.failed == 0 }

    var runnerName: String { TestRunner.named(runner)?.name ?? runner }

    /// What ran: the package, then the runner's own filters, without the
    /// subcommand every run of that runner carries.
    var scope: String? {
        let subcommands: Set<String> = runner == "playwright" ? ["test"] : ["run", "--run"]
        let filters = argv.filter { !subcommands.contains($0) }.joined(separator: " ")
        let parts = [package, filters.isEmpty ? nil : filters].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func relativeStart(now: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: startedDate, relativeTo: now)
    }

    func liveLine(now: Date) -> String {
        let elapsed = Duration.seconds(max(0, now.timeIntervalSince(startedDate)))
            .formatted(.time(pattern: .minuteSecond))
        let files = filesTotal > 0 ? localized("\(filesDone) of \(filesTotal) files") : nil
        return [files, elapsed, scope].compactMap { $0 }.joined(separator: " · ")
    }

    func finishedLine(now: Date) -> String {
        let duration = Duration.milliseconds(Int64(durationMs))
            .formatted(.units(allowed: [.minutes, .seconds], width: .narrow, fractionalPart: .show(length: 1)))
        let interrupted = state == "interrupted" ? localized("Interrupted") : nil
        return [interrupted, relativeStart(now: now), duration, scope].compactMap { $0 }.joined(separator: " · ")
    }

    /// One line per run in the picker, after the runner's mark: the result
    /// first, since that is what a look back is for, then when, then the
    /// command.
    func menuTitle(now: Date) -> String {
        let result: String
        if isRunning {
            result = localized("Running")
        } else if counts.failed > 0 {
            result = localized("\(counts.failed) failed")
        } else if failedWithoutFailedTests {
            result = localized("errors")
        } else if state == "interrupted" {
            result = localized("Interrupted")
        } else {
            result = localized("\(counts.passed) passed")
        }
        return [result, relativeStart(now: now), command].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A run's runner by its bundled logo, or the beaker for a runner newer than
/// this app.
private struct TestRunnerMark: View {
    let runner: String
    var size: CGFloat = 13

    var body: some View {
        if let image = Self.logo(runner: runner) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            HugeIconView(icon: .beaker, size: size, color: .secondary, lineWidthOverride: 1.5)
        }
    }

    /// A menu draws an image at its own size and ignores SwiftUI's frame, so
    /// the picker gets a copy sized for a menu row.
    static func menuImage(runner: String) -> Image {
        guard let logo = logo(runner: runner), let sized = logo.copy() as? NSImage else {
            return Image(systemName: "flask")
        }
        sized.size = NSSize(width: 14, height: 14)
        return Image(nsImage: sized)
    }

    private static func logo(runner: String) -> NSImage? {
        TestRunner.named(runner).flatMap { LangIconLoader.shared.image(named: $0.mark) }
    }
}

private struct TestRunStateIcon: View {
    let state: String

    var body: some View {
        switch state {
        case "running":
            ProgressView().controlSize(.mini)
        case "passed":
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case "failed":
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        default:
            Image(systemName: "minus.circle.fill").foregroundStyle(.orange)
        }
    }
}

private struct TestRunDetailView: View {
    let detail: Fyolod.TestRunDetail
    let open: (String) -> Void
    @State private var showsPassing: Bool

    /// With nothing failed, the passing files are all there is to show.
    init(detail: Fyolod.TestRunDetail, open: @escaping (String) -> Void) {
        self.detail = detail
        self.open = open
        _showsPassing = State(initialValue: detail.failures.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(failuresByFile, id: \.file) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.file ?? localized("Outside any test file"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    ForEach(Array(group.failures.enumerated()), id: \.offset) { _, failure in
                        TestFailureRow(failure: failure, open: open)
                    }
                }
            }
            if !passingFiles.isEmpty {
                passing
            }
            if failuresByFile.isEmpty, passingFiles.isEmpty {
                Text(localized("No results were recorded for this run."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }

    private var passing: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                showsPassing.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(showsPassing ? 90 : 0))
                    Text(passingFiles.count == 1
                        ? localized("\(passingTestCount) passed in 1 file")
                        : localized("\(passingTestCount) passed in \(passingFiles.count) files"))
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if showsPassing {
                ForEach(passingFiles, id: \.path) { file in
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.green)
                        Text(file.path)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 4)
                        Text("\(file.tests.filter { $0.state == "passed" }.count)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.leading, 12)
                    .contentShape(.rect)
                    .onTapGesture { open(file.path) }
                }
            }
        }
    }

    private var failuresByFile: [(file: String?, failures: [Fyolod.TestFailure])] {
        var order: [String?] = []
        var grouped: [String?: [Fyolod.TestFailure]] = [:]
        for failure in detail.failures {
            if grouped[failure.file] == nil { order.append(failure.file) }
            grouped[failure.file, default: []].append(failure)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    /// Files with tests that passed and nothing that failed.
    private var passingFiles: [Fyolod.TestFileResult] {
        detail.files.filter { file in
            file.state != "failed" && file.tests.contains { $0.state == "passed" }
        }
    }

    private var passingTestCount: Int {
        passingFiles.reduce(0) { $0 + $1.tests.filter { $0.state == "passed" }.count }
    }
}

private struct TestFailureRow: View {
    let failure: Fyolod.TestFailure
    let open: (String) -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.red)
                    Text(title)
                        .font(.system(size: 11))
                        .lineLimit(isExpanded ? nil : 1)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let message = failure.message {
                        Text(message)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    if let diff = failure.diff, !diff.isEmpty {
                        DiffText(diff: diff)
                    }
                    if let location = failure.location {
                        Button(location) { open(location) }
                            .buttonStyle(.link)
                            .font(.system(size: 10, design: .monospaced))
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
            }
        }
        .padding(.leading, 4)
    }

    private var title: String {
        switch failure.kind {
        case "module": localized("Failed to load")
        case "unhandled": localized("Unhandled error")
        default: failure.test ?? localized("Unnamed test")
        }
    }
}

/// A failure's diff, with its `-` (expected) and `+` (received) lines tinted
/// the way Vitest prints them. pytest's assertion diffs use the same signs.
private struct DiffText: View {
    let diff: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) {
                _, line in
                Text(line.isEmpty ? " " : String(line))
                    .foregroundStyle(line.hasPrefix("-") ? Color.green : line.hasPrefix("+") ? Color.red : Color.primary)
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .textSelection(.enabled)
    }
}
