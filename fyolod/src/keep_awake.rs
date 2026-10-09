//! Hold the machine out of idle sleep while stopping the daemon would take
//! work from someone.
//!
//! The failure this exists for: an agent prints a permission prompt and goes
//! quiet. While it was streaming, its pty counted as an active tty and
//! `pmset`'s default `ttyskeepawake` kept the machine up for free; the moment
//! it stops to wait, that cover lapses, the idle-sleep timer runs out, and the
//! phone that was supposed to answer the prompt can no longer reach the box.
//! The predicate is therefore [`SessionSummary::busy`] — the same "would
//! stopping take work" test the update path uses — not "is anyone attached";
//! see that method for why attachment is deliberately not the test.
//!
//! The assertion is a lease, not a held lock. While any session is busy, a
//! short-lived `caffeinate -i -t LEASE` process is renewed on a timer; when
//! nothing is busy the last lease simply runs out, which is also the grace
//! period. Nothing is ever released, so every exit path is covered by the same
//! non-mechanism: a crash, `fyolod stop`, and the `execve` handoff (which
//! runs no destructors and would orphan any long-lived child this module kept)
//! all leave at most one lease that expires on its own. `-i` limits the
//! assertion to idle system sleep — the display still sleeps.
//!
//! On battery no lease is taken at all. That has to be this module's own
//! check (`pmset -g batt` before each renewal): caffeinate's `-i` assertion
//! is honored on battery power, and `-s` does not scope it to AC — it only
//! adds a second, AC-only assertion. Unplugging mid-lease costs at most one
//! [`LEASE`] of battery-powered wakefulness.

use std::time::{Duration, Instant};

use crate::daemon::Manager;
use crate::lifecycle::SessionSummary;
use crate::protocol::Event;

/// How long one `caffeinate` child asserts for. Also the grace period: the
/// machine stays awake this long after the last session goes quiet.
const LEASE: Duration = Duration::from_secs(120);

/// How often a lease is renewed while sessions stay busy. Shorter than
/// [`LEASE`] so coverage is continuous across a missed tick.
const RENEW: Duration = Duration::from_secs(60);

/// When a wake decides to spawn a new lease.
///
/// Kept apart from the renewal loop because it has a real failure mode the
/// loop would hide: status events arrive in bursts, and a decision that
/// renewed on every wake would spawn a `caffeinate` per event instead of one
/// per [`RENEW`].
struct Renewal {
    last_lease: Option<Instant>,
}

impl Renewal {
    fn new() -> Renewal {
        Renewal { last_lease: None }
    }

    fn should_renew(&mut self, busy: bool, now: Instant) -> bool {
        if !busy {
            return false;
        }
        let due = match self.last_lease {
            None => true,
            // Strictly-greater keeps the periodic tick itself renewing: it
            // fires at exactly RENEW, and jitter only pushes it later.
            Some(last) => now.duration_since(last) >= RENEW,
        };
        if due {
            self.last_lease = Some(now);
        }
        due
    }
}

/// Runs for the daemon's life. Spawned only on macOS and only when keep-awake
/// is enabled; on every other platform the boxes fyolod runs on do not
/// idle-sleep and no assertion is needed.
pub async fn run(manager: Manager) {
    let mut events = manager.subscribe_events();
    let mut renewal = Renewal::new();
    let mut failure_reported = false;
    let mut tick = tokio::time::interval(RENEW);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    loop {
        tokio::select! {
            _ = tick.tick() => {}
            event = events.recv() => match event {
                // Status flips are the wakes that matter: they are how a
                // session becomes busy between ticks, and the first lease
                // should start then, not up to RENEW later. Roster changes
                // and exits only ever end busyness, which the running lease
                // already covers, but recomputing on them is free.
                Ok(Event::Status { .. })
                | Ok(Event::Roster { .. })
                | Ok(Event::SessionExited { .. }) => {}
                Ok(_) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                Err(tokio::sync::broadcast::error::RecvError::Closed) => return,
            }
        }

        let busy = manager
            .list()
            .await
            .into_iter()
            .any(|info| SessionSummary::from(info).busy());
        if busy && !on_alternating_current().await {
            continue;
        }
        if renewal.should_renew(busy, Instant::now()) {
            // A failed spawn is not the end of keep-awake: the clock it just
            // recorded makes the next due wake — the tick at the latest —
            // retry, and a transient fork failure will have cleared by then.
            // Reported only on the transition into failure, so a machine
            // where it never recovers logs once, not once a minute.
            if renew_lease().await {
                failure_reported = false;
            } else if !failure_reported {
                eprintln!("fyolod: keep-awake lease did not start; will keep retrying");
                failure_reported = true;
            }
        }
    }
}

/// Whether the machine is on AC power. An answer that cannot be read is
/// treated as AC: the feature exists to keep the box reachable, and the only
/// cost of guessing wrong on a machine where `pmset` is broken is a bounded
/// assertion, not a drained battery on a healthy one.
async fn on_alternating_current() -> bool {
    let output = tokio::process::Command::new("/usr/bin/pmset")
        .args(["-g", "batt"])
        .output()
        .await;
    match output {
        Ok(output) => !String::from_utf8_lossy(&output.stdout).contains("Battery Power"),
        Err(error) => {
            eprintln!(
                "fyolod: keep-awake could not read the power source, assuming AC: {error:#}"
            );
            true
        }
    }
}

/// Spawn one lease, detached from this process tree. `caffeinate` must not be
/// this daemon's child: the `execve` handoff keeps the pid but replaces every
/// in-memory child handle, so a lease inherited across it would sit unreaped
/// as a zombie until the daemon exits. Backgrounding it from a shell that
/// exits immediately reparents it to launchd, which reaps everything, and the
/// shell itself is waited on right here. `-t` bounds the lease's life either
/// way.
async fn renew_lease() -> bool {
    let spawned = tokio::process::Command::new("/bin/sh")
        .arg("-c")
        .arg(format!(
            "/usr/bin/caffeinate -i -t {} >/dev/null 2>&1 &",
            LEASE.as_secs()
        ))
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn();
    match spawned {
        Ok(mut shell) => matches!(shell.wait().await, Ok(status) if status.success()),
        Err(_) => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_busy_wake_leases_immediately() {
        let mut renewal = Renewal::new();
        assert!(renewal.should_renew(true, Instant::now()));
    }

    #[test]
    fn a_burst_of_busy_wakes_costs_one_lease() {
        let mut renewal = Renewal::new();
        let start = Instant::now();
        assert!(renewal.should_renew(true, start));
        assert!(!renewal.should_renew(true, start + Duration::from_millis(5)));
        assert!(!renewal.should_renew(true, start + RENEW - Duration::from_secs(1)));
    }

    #[test]
    fn the_periodic_tick_renews() {
        let mut renewal = Renewal::new();
        let start = Instant::now();
        assert!(renewal.should_renew(true, start));
        assert!(renewal.should_renew(true, start + RENEW));
    }

    #[test]
    fn quiet_sessions_never_lease_and_do_not_reset_the_clock() {
        let mut renewal = Renewal::new();
        let start = Instant::now();
        assert!(!renewal.should_renew(false, start));
        assert!(renewal.should_renew(true, start + Duration::from_secs(1)));
        assert!(!renewal.should_renew(false, start + Duration::from_secs(2)));
        assert!(renewal.should_renew(true, start + Duration::from_secs(1) + RENEW));
    }
}
