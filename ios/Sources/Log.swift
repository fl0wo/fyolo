import OSLog

/// Unified-logging categories for the iOS app. One `Logger` per subsystem area,
/// so Console.app and the `log` CLI can filter first-class:
///
///     log stream --predicate 'subsystem == "sh.fyolo.mobile" && category == "companion"'
///
/// Levels carry persistence semantics: `.debug` is memory-only (free in
/// release), `.info`/`.notice` are the default operational trail, and
/// `.error`/`.fault` are always persisted to disk. Interpolated values are
/// redacted by default — tag operational (non-sensitive) values `.public`;
/// never log the pairing token or anything that would grant access.
enum Log {
    private static let subsystem = "sh.fyolo.mobile"
    static let companion = Logger(subsystem: subsystem, category: "companion")
    /// The direct link to a device's own `fyolod` — a second backend behind the
    /// same screens, so its trail has to be filterable apart from the Mac's.
    static let device = Logger(subsystem: subsystem, category: "device")
    static let terminal = Logger(subsystem: subsystem, category: "terminal")
}
