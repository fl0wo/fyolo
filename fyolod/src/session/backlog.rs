//! What a client is allowed to have in flight, and what happens when it is not
//! keeping up.
//!
//! Pure policy: no PTY, no VT, no runtime. A session hands bytes to this and is
//! told whether they may be queued — the decision to drop a straggler and
//! resync it is made here and nowhere else, which is what keeps a slow socket
//! from buying unbounded memory on the host.

use bytes::Bytes;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};

/// How many bytes may sit queued for one client before it is dropped and
/// resynced. Per client on purpose: one slow socket must not be able to spend
/// the host's memory on everyone else's behalf.
const CLIENT_BACKLOG_CAP: usize = 4 * 1024 * 1024;

/// The limit in the words a log line or a refusal uses. Callers reporting *why*
/// a client was dropped should ask rather than restate the constant, so the
/// number and its explanation cannot drift apart.
/// The cap itself, for tests that need to build a payload sized against it.
#[cfg(test)]
pub(crate) const CAP_FOR_TESTS: usize = CLIENT_BACKLOG_CAP;

pub(crate) fn cap_description() -> String {
    format!("{} MiB", CLIENT_BACKLOG_CAP / (1024 * 1024))
}

/// A payload admitted against a client's backlog. The epoch pins it to the
/// reservation that let it through, so a forced resync can discard everything
/// already queued for that client without corrupting the count.
#[derive(Clone)]
pub struct Metered {
    pub(crate) bytes: Bytes,
    epoch: u64,
}

/// Counts PTY bytes queued anywhere between a session and its socket writer.
pub struct ClientBacklog {
    outstanding: AtomicUsize,
    /// Bumped by a forced resync. Everything reserved under an older epoch is
    /// stale: it precedes a snapshot that supersedes it, so it is dropped
    /// undelivered and never released.
    epoch: AtomicU64,
    dropped: AtomicBool,
}

impl ClientBacklog {
    pub(crate) fn new() -> Self {
        Self {
            outstanding: AtomicUsize::new(0),
            epoch: AtomicU64::new(0),
            dropped: AtomicBool::new(false),
        }
    }

    pub(crate) fn reserve(&self, bytes: Bytes) -> Option<Metered> {
        self.outstanding
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |outstanding| {
                outstanding
                    .checked_add(bytes.len())
                    .filter(|total| *total <= CLIENT_BACKLOG_CAP)
            })
            .ok()?;
        Some(Metered {
            bytes,
            epoch: self.epoch.load(Ordering::Acquire),
        })
    }

    /// True once the client has consumed everything the session handed it.
    #[cfg(test)]
    pub(crate) fn is_drained(&self) -> bool {
        self.outstanding.load(Ordering::Relaxed) == 0
    }

    /// Discard everything already queued for this client and start a new epoch.
    /// The queued payloads are dropped where they sit rather than released, so
    /// the counter is reset here instead of unwound.
    pub(crate) fn begin_resync(&self) {
        self.epoch.fetch_add(1, Ordering::AcqRel);
        self.outstanding.store(0, Ordering::Release);
    }

    /// True while this payload still belongs to the client's current stream.
    pub(crate) fn is_current(&self, payload: &Metered) -> bool {
        payload.epoch == self.epoch.load(Ordering::Acquire)
    }

    pub(crate) fn release(&self, payload: &Metered) {
        if !self.is_current(payload) {
            return;
        }
        let _ =
            self.outstanding
                .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |outstanding| {
                    Some(outstanding.saturating_sub(payload.bytes.len()))
                });
    }

    pub(crate) fn mark_dropped(&self) {
        self.dropped.store(true, Ordering::Release);
    }

    pub(crate) fn is_dropped(&self) -> bool {
        self.dropped.load(Ordering::Acquire)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chunk(len: usize) -> Bytes {
        Bytes::from(vec![b'x'; len])
    }

    #[test]
    fn client_backlog_enforces_byte_cap() {
        let backlog = ClientBacklog::new();

        let bulk = backlog
            .reserve(chunk(CLIENT_BACKLOG_CAP - 1))
            .expect("bulk reservation");
        let last = backlog.reserve(chunk(1)).expect("last byte");
        assert!(backlog.reserve(chunk(1)).is_none());

        backlog.release(&bulk);
        backlog.release(&last);
        assert!(backlog.is_drained());
        let after = backlog
            .reserve(chunk(1))
            .expect("reservation after release");
        backlog.release(&after);
    }

    #[test]
    fn resync_retires_queued_payloads_without_unwinding_the_count() {
        let backlog = ClientBacklog::new();
        let stale = backlog
            .reserve(chunk(CLIENT_BACKLOG_CAP))
            .expect("full reservation");
        assert!(backlog.reserve(chunk(1)).is_none());

        backlog.begin_resync();

        // The queued payload is dropped where it sits, so the client starts the
        // new epoch with the whole budget rather than waiting for a drain.
        assert!(!backlog.is_current(&stale));
        assert!(backlog.is_drained());
        let fresh = backlog
            .reserve(chunk(CLIENT_BACKLOG_CAP))
            .expect("fresh reservation");

        // A late release of a retired payload must not credit the new epoch.
        backlog.release(&stale);
        assert!(backlog.reserve(chunk(1)).is_none());
        backlog.release(&fresh);
        assert!(backlog.is_drained());
    }
}
