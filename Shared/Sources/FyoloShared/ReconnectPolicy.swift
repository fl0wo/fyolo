import Foundation

/// The reconnect cadence every self-healing link in fyolo shares: the phone's
/// two companion links (roster + terminal) and the Mac's own attach channel to
/// a session in fyolod.
///
/// Outages that look identical to a dead socket want opposite handling: an app
/// rebuild, a daemon restart or a Wi-Fi blip clears in seconds (retry fast,
/// notice the instant it's back), while a **closed laptop or a box that went
/// away** can be gone for hours (stop hammering the radio). So the cadence is
/// tiered — a fast burst for the first ~30s, then a slow 30s steady-state
/// heartbeat — rather than a retry-every-6s-forever loop.
///
/// It never gives up: a link self-heals instead of dead-ending in a
/// "disconnected" state that needs a manual tap. The event-driven wakeups
/// (app foreground, network path returning) are the *real* reconnect triggers
/// — they call `reset()` to drop back to the fast burst — and this backoff is
/// just the fallback for the case events miss (lid reopened on the same Wi-Fi
/// while the app is already foreground).
public struct ReconnectPolicy {
    /// Failed attempts since the last `reset()`. Exposed for logging/tests.
    public private(set) var attempts = 0

    public init() {}

    /// The next backoff delay in seconds, with ±20% jitter, advancing the
    /// attempt counter. `0.5 → 1 → 2 → 4 → 5` for the first six tries (~17s of
    /// failure), then a flat 30s heartbeat once the Mac is probably asleep, not
    /// rebuilding.
    public mutating func nextDelay(ceiling: Double = 30, jitter: ClosedRange<Double> = 0.8...1.2) -> Double {
        attempts += 1
        let base = attempts <= 6
            ? min(0.5 * pow(2.0, Double(attempts - 1)), 5)
            : ceiling
        return base * .random(in: jitter)
    }

    /// Back to the fast burst — called when an event says the Mac is likely
    /// reachable again (foreground, network path up, a manual "Try Again").
    public mutating func reset() {
        attempts = 0
    }
}
