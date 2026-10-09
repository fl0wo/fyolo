---
title: Session identity survives the agent
status: done
type: rfc
created: 2026-08-30
updated: 2026-08-31
related:
  - 20260829-tab-strip-is-the-collapsed-sidebar.md
  - 20260827-fyolod-lifecycle-reconcile.md
---

# Session identity survives the agent

> A session the app created must never reappear under "Also Running". This RFC
> fixes issue #528 by making destroy name-addressed, agent exit visible, and the
> stranger filter honest — following the identity model tmux and herdr both use.

## The bug (#528)

A built-in Claude Code or Codex session runs as:

```text
fyolod
└─ /bin/zsh -il
   └─ codex | claude
```

The user exits the agent normally. The outer login shell survives, and the
session's sidebar row disappears — replaced by an entry under **Also Running**
named `zsh`. The user must reattach and `exit` a second time to be rid of it.
The reporter's complaint is exact: the session changed identity silently, so a
finished task reads as a process leak.

## Three root causes

These are separate defects that compound. All file references are current as of
this writing.

### 1. Destroy depends on a lazily-created link

`closeSession` kills the daemon-side session through exactly one line
(`Sources/fyolo/FyoloStore/FyoloStore+ProjectActions.swift:1003`):

```swift
fyolodLinks[id]?.killAndClose()
fyolodLinks[id] = nil
```

The `?.` is the bug. A `FyolodSessionLink` is created only when a pane
actually renders (`surface(for:)` →
`makeFyolodLink` in `FyoloStore+TerminalSurface.swift:287`), and it is
cleared in several places — first thing in `applyFyolodExit`
(`FyoloStore+Fyolod.swift:375`), on connection loss, and wholesale on app
quit. So every one of these closes silently kills nothing:

- a row restored after app relaunch that was never selected,
- a close from the CLI or the phone for a row never viewed this run,
- any close after the exit/connection-lost paths nil'd the link.

The same pattern repeats at `removeProject`
(`FyoloStore+ProjectActions.swift:857`) and `relaunchSession` (`:1063`).
`relaunchSession` is the worst case: its comment promises "a respawn-in-place
must not leave the old daemon-side process running under the same name", but on
the revert-to-shell path the kill is *always* a no-op, because
`applyFyolodExit` already nil'd the link before calling it.

The irony: `killAndClose()` itself already kills by name
(`Terminal/Fyolod/FyolodClient.swift:1292`), and `closeDeviceSessions`
already does a link-free kill for stranger rows
(`FyoloStore+Fyolod.swift:770`). The capability exists; `closeSession` just
doesn't use it when the link is gone.

### 2. Agent exit inside a surviving shell is invisible

The launch wrapper is `[shell, "-ilc", "exec \(command)"]`
(`FyoloStore+TerminalSurface.swift:502`). When the `exec` actually replaces
the shell, agent exit ends the daemon session, `link.onExit` fires, and
`applyFyolodExit` reverts the row to a shell in place — the designed behavior.

The issue's process tree shows a shell that did **not** exec: the agent ran as
a child of `zsh -il`. (A `claude`/`codex` that resolves to a shell function or
alias shim in the user's zshrc is enough — `exec` of a function cannot replace
the process.) In that tree the daemon session never exits, so no exit event
ever fires. And the app deliberately never demotes a declared agent row from
foreground data — `applyFyolodInformation` is wired with
`identifiesAgent: isPlainTerminal` (`FyoloStore+Fyolod.swift:135`). Net
effect: no code path in the app can notice the agent left.

fyolod, for its part, already reports everything needed: the foreground
sampler (`fyolod/src/session/foreground.rs`, 2s cadence) publishes
`foreground_pid` / `foreground_argv` per session, and `zsh` in an Also Running
row is precisely that sampler reporting an idle login shell.

### 3. The stranger filter can't tell strangers from our own orphans

"Also Running" was designed (tab-strip RFC) as *sessions the device reports
that no row accounts for* — the adoption affordance for sessions started from
the `fyolod` CLI. The filter (`FyoloStore/DeviceContext.swift:205`) is:

```swift
guard information.alive else { return false }
guard !mine.contains(where: { daemonSessionName(for: $0) == information.name }) else { return false }
if isLocal, information.attachedClients > 0 { return false }
```

An app-created session whose row was closed link-lessly satisfies all three
within one roster refresh. The filter checks *live* rows only; the app keeps no
record of sessions it closed, so its own orphan is indistinguishable from a
genuine CLI-started stranger.

## What tmux and herdr do

Both competitors converge on one principle: **identity belongs to the session
object; the foreground process is an attribute of it.**

- **tmux** — a pane's identity never changes when its process exits. Default:
  the pane dies with the process. With `remain-on-exit`, the pane stays *in
  place*, explicitly marked dead ("Pane is dead"), and `respawn-pane` revives
  it in the same spot. There is no path on which a pane migrates to a
  different list under a different name.
- **herdr** — the pane is the stable identity and the agent is *detected
  inside* it ("each agent stays in a real terminal pane with its shell").
  Agent exit rolls the pane's state back to idle/unknown; the pane stays where
  it is. There is no orphan bucket at all. External sessions are handled by
  detection and state roll-up, not by a separate section.

Fyolo's revert-to-shell is already the right call by this standard — it is
tmux's `remain-on-exit` with a live shell instead of a dead pane. The bug is
that on the non-exec tree the revert never runs, and that close can leak the
daemon session into a bucket that changes its identity.

## Design

### D1. Destroy is name-addressed, never link-addressed

The `(daemon name, route)` pair is the destroy capability. The link is a live
attachment — an optimization, never a prerequisite.

`closeSession`, `removeProject`, and `relaunchSession` kill unconditionally by
name, exactly as `closeDeviceSessions` already does:

```swift
if let link = fyolodLinks[id] {
    link.killAndClose()
} else {
    Fyolod.killSession(
        target: daemonSessionName(for: session),
        route: FyolodRoute(sshAlias: session.fyolodRemoteHost))
}
fyolodLinks[id] = nil
```

`closeSession` already reads the session before mutating (`locate(id)` at
`:998`), so name and route are available. "No such session" stays a benign
answer, as it already is in `FyolodClient.swift:829`.

If the route is unreachable at close time (remote host offline), record the
`(name, route)` pair as a pending kill and retry on the next successful roster
refresh for that route. A small persisted ring is enough; this also closes the
close-while-offline hole that no link-based scheme could.

### D2. Agent exit is detected by foreground, not only by process exit

Keep both exit shapes converging on the same UX — the row stays in place:

- **Exec'd tree** (daemon child *is* the agent): unchanged —
  `applyFyolodExit` → revert to shell in place. D1 fixes `relaunchSession` so
  the respawn actually replaces the old daemon session instead of reattaching
  to it.
- **Wrapped tree** (agent is a child of a surviving shell): let foreground data
  demote a declared agent row. When a declared-agent session's
  `foreground_argv` has reported the shell for a stable streak (same streak
  machinery status promotion already uses), transition the row in place:
  status → idle, subtitle → "Claude Code exited — shell". The
  `identifiesAgent: isPlainTerminal` asymmetry stays for *promotion* (a
  declared row never gets re-identified as a different agent), but demotion to
  "agent gone, shell remains" becomes an explicit, visible state.

The issue asks for one of: kill the outer shell too, keep the shell clearly
labeled in place, or a setting. This RFC picks **labeled in place** as the only
behavior — it is tmux's `remain-on-exit` semantics and herdr's idle roll-back,
it preserves scrollback, and it matches "the session lives on the box". A
setting is surface area we don't need until someone asks for the kill
behavior.

### D3. "Also Running" shows true strangers only

The app remembers the daemon names of sessions it has closed (the same ring
that D1's pending kills use — a closed-session journal keyed by daemon name,
bounded, persisted in `StateFile`). At roster refresh:

- live daemon session whose name matches a **current row** → accounted for
  (already the case),
- name matches a **journaled close** → not a stranger: kill it on sight.
  D1 should have killed it; this sweep is the belt-and-braces that makes the
  invariant hold even across crashes and offline closes,
- anything else → a genuine stranger; show it for adoption as designed.

The journal, not name shape, decides "mine": two Fyolo installs share one
per-uid daemon roster, so a UUID-shaped name alone proves nothing about whose
session it is.

### The verdict on the section itself

Keep the mechanism, fix its diet. Adopting `fyolod`-CLI sessions into the
sidebar is real product surface — it is the "one roster, any client" half of
the positioning, and herdr validates external-session detection as the
category norm. What #528 shows is not that the section is a bad idea but that
it was fed sessions whose identity the app already owned. After D1–D3 it
appears only when someone genuinely started a session outside the app — which
for most users is never, and that is the correct frequency for it.

## Testing

- `Tests/fyoloTests/FyolodDestroyIntegrationTests.swift` installs the link by
  hand (`:104`), so the link-present path is the only one ever exercised — the
  #528 close path has zero coverage. Add the link-less cases: close of a
  restored row, close after `applyFyolodExit`, close from the CLI path.
- Unit-test the D3 filter with a journaled close: roster row matching a
  journaled name must be killed, not listed.
- The D2 demotion streak is pure logic over `SessionInfo` sequences — testable
  without a window, same shape as `StallProbeTests`.
- Manual: reproduce the issue's tree by shadowing `claude` with a zsh function
  in a probe channel (`FYOLO_CHANNEL=probe`), exit the agent, confirm the row
  demotes in place; close it, confirm the daemon roster is empty.

## Non-goals

- #526/#527 (connect-failure daemon spawning) are a different root cause and
  tracked separately.
- No daemon-side "owner" metadata. fyolod stays client-agnostic; ownership is
  the app's bookkeeping (the journal), which also keeps two installs sharing a
  roster honest.
- No change to revert-to-shell as the designed outcome of agent exit, and no
  nested window manager anywhere in the host.
