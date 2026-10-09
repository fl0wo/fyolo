import Foundation

/// Distinguishes a shipped release from a side-by-side **dev** build so the two
/// can run at once without fighting over on-disk state, control sockets, or the
/// companion port.
///
/// Everything keys off the bundle identifier: a dev build ships an id ending in
/// `.dev` (`sh.fyolo.app.dev`), and that single fact fans out here into every
/// fyolo-owned path and port. A release build (`sh.fyolo.app`) is unsuffixed and
/// behaves exactly as before. UserDefaults and LaunchServices already isolate by
/// bundle id for free; this type covers the paths that don't.
///
/// Note: a *project's* own `<project>/.fyolo/…` sidecar (phone uploads, etc.) is
/// deliberately NOT routed through here — it's relative to the user's repo, not to
/// fyolo's config, so both channels share it.
enum AppChannel {
    /// `"-dev"` for a `*.dev` bundle id, `""` for a release build.
    ///
    /// A fyolo `.app` reads its channel off its own bundle identifier, and
    /// nothing overrides that: every fyolo session carries the channel of
    /// the app that spawned it in `FYOLO_CHANNEL`, and macOS `open`
    /// propagates the caller's environment — so launching the dev app from a
    /// release session (or the reverse) would otherwise rebind the app to
    /// the *other* channel's state directory, control socket, and companion
    /// port. The `FYOLO_CHANNEL` override exists for the unbundled case
    /// only: `swift run` has no bundle identifier, so without it a bare
    /// binary falls into the release channel and shares the shipped app's
    /// state.
    static let suffix: String = {
        let requested = ProcessInfo.processInfo.environment["FYOLO_CHANNEL"]?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        // A custom probe channel is always deliberate — only a test harness
        // sets one — and only a plain name becomes a path component: anything
        // else is a typo we must not turn into a stray directory.
        if !requested.isEmpty, requested != "release", requested != "dev",
           requested.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
            return "-" + requested
        }
        // The two real channel names are the ones a session's environment
        // carries, so for them the app's own identity wins.
        if let identifier = Bundle.main.bundleIdentifier,
           identifier == "sh.fyolo.app" || identifier.hasSuffix(".dev") {
            return identifier.hasSuffix(".dev") ? "-dev" : ""
        }
        return requested == "dev" ? "-dev" : ""
    }()

    /// True for the side-by-side dev build. Use this to gate diagnostics that must
    /// survive a release-configuration compile (`build-app.sh` builds the dev bundle
    /// in release config, so `#if DEBUG` would strip them) yet never appear in the
    /// shipped release app.
    static var isDev: Bool { !suffix.isEmpty }

    /// The URL scheme this channel claims for session deep links (`fyolo://` /
    /// `fyolo-dev://`), so dev and release never route each other's links.
    /// Registered in Info.plist; `build-app.sh` rewrites it for the dev bundle.
    static var urlScheme: String { "fyolo" + suffix }

    /// The identifier a shipped fyolo carries. `build-app.sh` stamps this one for
    /// the release channel and appends `.dev` for the side-by-side dev build, and
    /// it refuses to build any other channel — so these two are the complete set.
    private static let releaseBundleIdentifier = "sh.fyolo.app"

    /// True when this process *is* one of fyolo's own `.app` bundles. It gates the
    /// bundle-dependent frameworks: `UNUserNotificationCenter` aborts the process
    /// with "bundleProxyForCurrentProcess is nil" unless the running bundle is one
    /// LaunchServices knows.
    ///
    /// Asking the weaker question — "is there *a* bundle identifier?" — passed under
    /// `swift test`, whose `xctest` host is bundled as Xcode's own tool and so
    /// carries an identifier that buys the framework nothing. Every test that moved
    /// the store's selection died on `SIGABRT` inside `markSeen`.
    static let isFyoloAppBundle: Bool = {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        return identifier == releaseBundleIdentifier
            || identifier == releaseBundleIdentifier + ".dev"
    }()

    /// True when this process is a test binary rather than either fyolo.
    ///
    /// `swift test` has no bundle id ending in `.dev` and no `FYOLO_CHANNEL`, so
    /// without this it lands on the **release** channel — and `FyoloStore`
    /// persists on every `projects` mutation, so a test that builds a store over
    /// fixture projects overwrites the installed app's session tree. That is not a
    /// hypothetical: it has replaced a real user's projects with `/code/fyolo`.
    /// The channel suffix is deliberately left alone; only the directories that
    /// get written move, since the ports and URL scheme are never claimed here.
    static let isRunningTests: Bool = NSClassFromString("XCTestCase") != nil

    /// A scratch home for a test run, thrown away with the rest of the temp
    /// directory. Keyed by pid so two concurrent runs can't read each other's
    /// writes.
    private static let testDirectory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "fyolo-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    /// Internal state — control/status sockets, `state.json`, custom themes, and
    /// downloaded tunnel binaries: `~/Library/Application Support/fyolo[-dev]`.
    /// Falls back to a home dotfolder if Application Support can't be resolved.
    static var supportDirectory: URL {
        if isRunningTests {
            return testDirectory.appendingPathComponent("support", isDirectory: true)
        }
        let name = "fyolo" + suffix
        if let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return base.appendingPathComponent(name, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("." + name, isDirectory: true)
    }

    /// User-facing config the user drops files into (agent definitions, worktrees):
    /// `~/.fyolo[-dev]`.
    static var homeConfigDirectory: URL {
        if isRunningTests {
            return testDirectory.appendingPathComponent("home", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fyolo" + suffix, isDirectory: true)
    }

    /// Companion (phone) server port: 8787 for release, 8788 for dev, so both can
    /// bind at once.
    static var companionPort: UInt16 { suffix.isEmpty ? 8787 : 8788 }

    /// Where a phone dials this Mac's session host (`DeviceSpliceServer`): 8795
    /// for release, 8796 for dev. Clear of the companion pair above and of the
    /// daemon's own loopback listener on 8790, so a Mac running all three has
    /// nothing to fight over.
    static var devicePort: UInt16 { suffix.isEmpty ? 8795 : 8796 }
}
