import AppKit
import CryptoKit
import SwiftUI

/// A release's `MAJOR.MINOR.PATCH`, ordered numerically — `0.10.0` is newer than
/// `0.9.0`, which a string comparison gets backwards. A leading `v` (the tag) and
/// anything after `-` or `+` (a prerelease or build suffix) are ignored.
struct ReleaseVersion: Comparable, CustomStringConvertible {
    let components: [Int]

    init?(_ text: String) {
        var core = Substring(text.trimmingCharacters(in: .whitespaces))
        if core.hasPrefix("v") { core = core.dropFirst() }
        if let suffix = core.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            core = core[..<suffix]
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (1 ... 3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        components = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }

    var description: String { components.map(String.init).joined(separator: ".") }
}

/// The `latest.json` each release publishes beside its DMG
/// (`scripts/release-manifest.sh`).
struct ReleaseManifest: Decodable, Equatable {
    let version: String
    /// The oldest release still allowed to run.
    let minimumVersion: String
    let notesURL: URL?
    let dmgURL: URL
    let sha256: String
    /// The Homebrew cask a brew install upgrades, tap-qualified.
    let cask: String

    private enum CodingKeys: String, CodingKey {
        case version
        case minimumVersion = "minimum_version"
        case notesURL = "notes_url"
        case dmgURL = "dmg_url"
        case sha256
        case cask
    }
}

/// What the latest release means for the running one.
enum UpdateVerdict: Equatable {
    case current
    /// Newer, and this version may keep running: offered, never pressed.
    case available(ReleaseManifest)
    /// This version is below the release's floor: the app blocks until updated.
    case required(ReleaseManifest)

    var manifest: ReleaseManifest? {
        switch self {
        case .current: return nil
        case .available(let manifest), .required(let manifest): return manifest
        }
    }

    /// `nil` when the manifest's own version does not parse — a manifest that
    /// cannot say what it offers decides nothing.
    static func of(running: ReleaseVersion, manifest: ReleaseManifest) -> UpdateVerdict? {
        guard let latest = ReleaseVersion(manifest.version) else { return nil }
        guard running < latest else { return .current }
        // A floor above the release it ships with is bad data: believing it would
        // block every install with nothing to update to. The release script refuses
        // to publish one; this refuses to act on one that got out anyway.
        if let floor = ReleaseVersion(manifest.minimumVersion), floor <= latest, running < floor {
            return .required(manifest)
        }
        return .available(manifest)
    }
}

/// How this copy of fyolo was installed, which decides how it updates.
enum InstallMethod: Equatable {
    /// A Homebrew cask: updating is `brew upgrade --cask`, so brew's record of
    /// what is installed stays true.
    case homebrew(brew: URL)
    /// A DMG dragged into Applications: updating is the next DMG.
    case direct

    /// A cask install leaves `<prefix>/Caskroom/fyolo` behind — a stat, not a
    /// `brew` launch, so it costs nothing at startup.
    static func detect(
        prefixes: [String] = ["/opt/homebrew", "/usr/local"], fileManager: FileManager = .default
    ) -> InstallMethod {
        for prefix in prefixes where fileManager.fileExists(atPath: prefix + "/Caskroom/fyolo") {
            let brew = URL(fileURLWithPath: prefix + "/bin/brew")
            if fileManager.isExecutableFile(atPath: brew.path) { return .homebrew(brew: brew) }
        }
        return .direct
    }
}

/// Learns whether a newer fyolo exists and carries out the update.
///
/// The newest release is read from `latest.json` through GitHub's
/// `releases/latest/download/` redirect: a static file on the release itself, so
/// there is no server to run, no API rate limit to share with everyone behind
/// the same address, and nothing sent but the request. A check that fails —
/// offline, GitHub down, a malformed file — changes nothing; in particular it
/// can never put up the blocking sheet.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    enum Phase: Equatable {
        case idle
        case downloading
        case upgrading
        /// The DMG is open in the Finder; the user drags the app across.
        case diskImageOpened
        /// A newer fyolo is on disk than the one running.
        case readyToRelaunch
        case failed(String)
    }

    @Published private(set) var verdict: UpdateVerdict = .current
    @Published private(set) var phase: Phase = .idle
    /// Hides the sidebar offer until this moment ("Later").
    @Published private var snoozedUntil: Date?
    @Published private var skippedVersion: String? =
        UserDefaults.standard.string(forKey: UpdateChecker.skippedVersionKey)

    let runningVersion: ReleaseVersion?
    let installMethod = InstallMethod.detect()
    private let manifestURL: URL?
    private var schedule: Task<Void, Never>?
    private var lastCheck: Date?

    static let releaseManifestURL =
        URL(string: "https://github.com/fl0wo/fyolo/releases/latest/download/latest.json")
    private static let skippedVersionKey = "updates.skippedVersion"
    private static let checkInterval: TimeInterval = 12 * 60 * 60

    private init() {
        let info = Bundle.main.infoDictionary
        runningVersion = (info?["CFBundleShortVersionString"] as? String).flatMap(ReleaseVersion.init)
        // `FYOLO_UPDATE_MANIFEST` points any build at a manifest of its own — a
        // `file://` URL works — which is how the update UI is exercised without
        // publishing a release. Otherwise only a shipped release checks: a dev
        // build would offer to replace itself with the release, and an unbundled
        // `swift run` has no version to compare.
        if let override = ProcessInfo.processInfo.environment["FYOLO_UPDATE_MANIFEST"],
           let url = URL(string: override) {
            manifestURL = url
        } else if AppChannel.isDev || info?["CFBundleVersion"] == nil {
            manifestURL = nil
        } else {
            manifestURL = Self.releaseManifestURL
        }
    }

    /// Whether this build checks at all.
    var isEnabled: Bool { manifestURL != nil && runningVersion != nil }

    /// Whether the sidebar should offer the update: an optional one the user has
    /// neither skipped nor put off, or one already under way.
    var offersUpdate: Bool {
        guard case .available(let manifest) = verdict else { return false }
        if phase != .idle { return true }
        if manifest.version == skippedVersion { return false }
        if let snoozedUntil, Date() < snoozedUntil { return false }
        return true
    }

    /// Checks shortly after launch — the first window gets the network first —
    /// then every twelve hours, and on coming back to the app once that is due.
    func start() {
        guard isEnabled, schedule == nil else { return }
        schedule = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(Self.checkInterval))
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameActive() }
        }
    }

    /// One check. A failure leaves the verdict as it was and is returned for the
    /// menu item to report; the background schedule only logs it.
    @discardableResult
    func check() async -> Result<UpdateVerdict, Error> {
        guard let manifestURL, let runningVersion else {
            return .failure(UpdateCheckError.disabled)
        }
        lastCheck = Date()
        do {
            // The URL cache would answer a repeat check from the copy GitHub's
            // `max-age` allows it to keep, and a check exists to ask again.
            let request = URLRequest(
                url: manifestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                throw UpdateCheckError.status(http.statusCode)
            }
            let manifest = try JSONDecoder().decode(ReleaseManifest.self, from: data)
            guard let verdict = UpdateVerdict.of(running: runningVersion, manifest: manifest) else {
                throw UpdateCheckError.malformed
            }
            if verdict != self.verdict { self.verdict = verdict }
            return .success(verdict)
        } catch {
            Log.app.error("update check: \(String(describing: error), privacy: .public)")
            return .failure(error)
        }
    }

    func skipOfferedVersion() {
        guard let version = verdict.manifest?.version else { return }
        skippedVersion = version
        UserDefaults.standard.set(version, forKey: Self.skippedVersionKey)
    }

    func snooze() {
        snoozedUntil = Date().addingTimeInterval(24 * 60 * 60)
    }

    /// Updates the way this copy was installed. A Homebrew install upgrades its
    /// cask; anything else downloads the release's DMG, checks it against the
    /// manifest's hash, and opens it.
    func update() {
        guard let manifest = verdict.manifest else { return }
        switch phase {
        case .downloading, .upgrading: return
        case .readyToRelaunch: relaunch(); return
        default: break
        }
        switch installMethod {
        case .homebrew(let brew): upgrade(with: brew, cask: manifest.cask)
        case .direct: downloadDiskImage(manifest)
        }
    }

    /// Quits and opens the copy now on disk once this process is gone. Sessions
    /// live in fyolod, so the relaunch picks every one of them back up.
    func relaunch() {
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = [
            "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$2\"",
            "relaunch", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path,
        ]
        do {
            try relauncher.run()
        } catch {
            phase = .failed(localized("Couldn’t relaunch fyolo. Quit and open it again."))
            Log.app.error("relaunch: \(String(describing: error), privacy: .public)")
            return
        }
        NSApp.terminate(nil)
    }

    /// The command a person can run themselves when the upgrade fails, quoted in
    /// the failure so it can be copied.
    var homebrewCommand: String {
        "brew upgrade --cask \(verdict.manifest?.cask ?? "fl0wo/tap/fyolo")"
    }

    // MARK: - Updating

    private func upgrade(with brew: URL, cask: String) {
        // The cask comes from the manifest; an argument that reads as a flag is
        // not a cask name, whatever the file says.
        guard !cask.hasPrefix("-"), !cask.isEmpty else {
            phase = .failed(localized("Homebrew couldn’t update fyolo. Run \(homebrewCommand) in a terminal to see why."))
            return
        }
        phase = .upgrading
        Task {
            let outcome = await Self.run(brew, arguments: ["upgrade", "--cask", cask])
            // brew's exit status is not the answer: "already up-to-date" exits 0
            // with nothing changed. A newer app on disk is.
            if let installed = Self.installedVersion(), let runningVersion, installed > runningVersion {
                phase = .readyToRelaunch
                return
            }
            Log.app.error("brew upgrade: \(outcome, privacy: .public)")
            phase = .failed(localized("Homebrew couldn’t update fyolo. Run \(homebrewCommand) in a terminal to see why."))
        }
    }

    private func downloadDiskImage(_ manifest: ReleaseManifest) {
        phase = .downloading
        Task {
            do {
                let (download, response) = try await URLSession.shared.download(from: manifest.dmgURL)
                defer { try? FileManager.default.removeItem(at: download) }
                if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                    throw UpdateCheckError.status(http.statusCode)
                }
                guard try Self.sha256(of: download) == manifest.sha256.lowercased() else {
                    phase = .failed(localized("The download didn’t match the release. Nothing was installed."))
                    return
                }
                let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? FileManager.default.temporaryDirectory
                let image = folder.appendingPathComponent("fyolo-\(manifest.version).dmg")
                try? FileManager.default.removeItem(at: image)
                try FileManager.default.moveItem(at: download, to: image)
                // Downloaded by this process rather than a browser, so it carries
                // no quarantine flag and the unsigned app inside opens normally.
                NSWorkspace.shared.open(image)
                phase = .diskImageOpened
            } catch {
                Log.app.error("update download: \(String(describing: error), privacy: .public)")
                phase = .failed(RemoteFileFailure.message(
                    for: error, fallback: localized("The download failed.")))
            }
        }
    }

    private func appBecameActive() {
        // Dragging the new app across happens in the Finder; coming back is when
        // there is something to relaunch into.
        if phase == .diskImageOpened || phase == .upgrading,
           let installed = Self.installedVersion(), let runningVersion, installed > runningVersion {
            phase = .readyToRelaunch
        }
        if let lastCheck, Date().timeIntervalSince(lastCheck) >= Self.checkInterval {
            Task { await check() }
        }
    }

    /// The version of the app bundle on disk now — newer than the one running once
    /// an update has replaced it. Read from the file: `Bundle` caches what it
    /// loaded at launch.
    static func installedVersion() -> ReleaseVersion? {
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String
        else { return nil }
        return ReleaseVersion(version)
    }

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Runs a command to completion off the main thread and returns its exit
    /// status and the tail of its output, for the log. Output goes to a file
    /// rather than a pipe: brew can print more than a pipe buffers, and a full
    /// pipe nobody drains stalls the process.
    private static func run(_ executable: URL, arguments: [String]) async -> String {
        await withCheckedContinuation { continuation in
            let log = FileManager.default.temporaryDirectory
                .appendingPathComponent("fyolo-update-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            // A GUI app's PATH is the bare system one; brew wants its own prefix.
            environment["PATH"] = executable.deletingLastPathComponent().path
                + ":/usr/bin:/bin:/usr/sbin:/sbin"
            // brew refreshes taps only once a day by default, and a tap it has not
            // refreshed does not know the release exists yet.
            environment["HOMEBREW_AUTO_UPDATE_SECS"] = "0"
            environment.removeValue(forKey: "HOMEBREW_NO_AUTO_UPDATE")
            environment["HOMEBREW_NO_ENV_HINTS"] = "1"
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            if let output = try? FileHandle(forWritingTo: log) {
                process.standardOutput = output
                process.standardError = output
            }
            process.terminationHandler = { finished in
                let tail = (try? String(contentsOf: log, encoding: .utf8))
                    .map { String($0.suffix(2000)) } ?? ""
                try? FileManager.default.removeItem(at: log)
                continuation.resume(returning: "exit \(finished.terminationStatus): \(tail)")
            }
            do {
                try process.run()
            } catch {
                try? FileManager.default.removeItem(at: log)
                continuation.resume(returning: "could not start: \(error)")
            }
        }
    }
}

enum UpdateCheckError: Error, LocalizedError {
    case disabled
    case status(Int)
    case malformed

    var errorDescription: String? {
        switch self {
        case .disabled: return localized("This build doesn’t check for updates.")
        case .status(let code): return localized("GitHub replied with HTTP \(code).")
        case .malformed: return localized("The release’s update information couldn’t be read.")
        }
    }
}

// MARK: - Views

/// What the update is doing, in one line — shared by the sidebar offer and the
/// blocking sheet so both say the same thing.
@MainActor
private func updateStatus(_ checker: UpdateChecker) -> String {
    switch checker.phase {
    case .idle:
        if case .homebrew = checker.installMethod { return localized("Updates with Homebrew.") }
        return localized("Downloads the new version.")
    case .downloading: return localized("Downloading…")
    case .upgrading: return localized("Updating with Homebrew…")
    case .diskImageOpened: return localized("Open the disk image and drag fyolo to Applications.")
    case .readyToRelaunch: return localized("Relaunch to finish updating.")
    case .failed(let message): return message
    }
}

@MainActor
private func updateActionTitle(_ checker: UpdateChecker) -> String {
    checker.phase == .readyToRelaunch ? localized("Relaunch") : localized("Update")
}

@MainActor
private func updateIsBusy(_ checker: UpdateChecker) -> Bool {
    checker.phase == .downloading || checker.phase == .upgrading
}

/// The sidebar's offer of an optional update. Quiet by design — the same neutral
/// card as the agent-status nudge, never a modal for something the user may
/// decline.
struct UpdateAvailableBanner: View {
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        if checker.offersUpdate, let manifest = checker.verdict.manifest {
            HStack(spacing: 9) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(localized("fyolo \(manifest.version) is available"))
                        .font(.callout.weight(.medium))
                    Text(updateStatus(checker))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if updateIsBusy(checker) {
                    ProgressView().controlSize(.small)
                } else {
                    Button(updateActionTitle(checker)) { checker.update() }
                        .buttonStyle(.borderless)
                        .font(.callout.weight(.medium))
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .contextMenu {
                if let notes = manifest.notesURL {
                    Button(localized("Release Notes")) { NSWorkspace.shared.open(notes) }
                }
                Button(localized("Later")) { checker.snooze() }
                Button(localized("Skip This Version")) { checker.skipOfferedVersion() }
            }
            .padding(.vertical, 4)
        }
    }
}

/// The sheet over the window when this version may no longer run. It has no way
/// out but updating or quitting; quitting costs nothing, because every session
/// lives on in fyolod and is there again on the next launch.
struct UpdateRequiredView: View {
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localized("Update Required"))
                .font(.title3.weight(.semibold))
            Text(localized("fyolo \(checker.runningVersion?.description ?? "") is no longer supported. Update to \(checker.verdict.manifest?.version ?? "") to keep using it."))
                .fixedSize(horizontal: false, vertical: true)
            Text(localized("Your sessions keep running while you update."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if updateIsBusy(checker) { ProgressView().controlSize(.small) }
                Text(updateStatus(checker))
                    .font(.callout)
                    .foregroundStyle(failed ? Color.red : Color.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let notes = checker.verdict.manifest?.notesURL {
                    Button(localized("Release Notes")) { NSWorkspace.shared.open(notes) }
                        .buttonStyle(.link)
                }
                Spacer()
                Button(localized("Quit fyolo")) { NSApp.terminate(nil) }
                Button(updateActionTitle(checker)) { checker.update() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(updateIsBusy(checker))
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 420)
    }

    private var failed: Bool {
        if case .failed = checker.phase { return true }
        return false
    }
}
