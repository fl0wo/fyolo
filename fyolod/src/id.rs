//! The host's identities.
//!
//! A client id, a session id and a session name were all `String`, and they all
//! flow through the same functions: a client id keys a session's roster, a
//! session id keys the session table and the graveyard, and a user-supplied
//! target — which may be an id *or* a name — arrives from the wire looking
//! exactly like both. Nothing but the type told them apart, so the type is what
//! tells them apart.
//!
//! These are host-side only. The wire keeps bare JSON strings, because that is
//! what a JSON string is: `SessionInfo.id` and `Control::HelloOk.client_id` stay
//! `String`, and every crossing into or out of them is a visible `new` or
//! `to_string`. Swift sees no difference.

use std::fmt;

/// One connection to this host. Allocated per accepted connection, never reused
/// within a daemon's life, and the key of both a session's client roster and the
/// resource registry's subscriber tables.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ClientId(String);

impl ClientId {
    /// Take a string the caller vouches for. Every call site is a boundary: the
    /// daemon minting an id for a connection it just accepted.
    pub fn new(id: impl Into<String>) -> ClientId {
        ClientId(id.into())
    }

    /// A subscriber that is not a connection. The resource registry's `git:`
    /// kind rides the `fs:` watcher by subscribing to it and needs a key for
    /// that interest; naming the constructor keeps the fabrication visible
    /// rather than leaving a `format!` that reads like a real client.
    pub fn internal(id: impl Into<String>) -> ClientId {
        ClientId(id.into())
    }

    /// Only the assertions need this: everything in the host either keys a map
    /// with a whole `ClientId` or renders one through `Display`.
    #[cfg(test)]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for ClientId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// One session on this host. Distinct from the *name* a session carries, which
/// a user picks; distinct again from the target a client sends, which is either
/// of the two and must be resolved against the table before anything indexes
/// with it.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SessionId(String);

impl SessionId {
    /// Take a string the caller vouches for: an id the daemon minted, or one
    /// read back out of a record the daemon wrote.
    pub fn new(id: impl Into<String>) -> SessionId {
        SessionId(id.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for SessionId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}
