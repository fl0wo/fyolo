---
title: Keyboard and command design
status: active
type: design
created: 2026-08-12
updated: 2026-08-25
---

# Keyboard and command design

> One rule decides every binding: a key either changes what you're looking at or
> it ends a process, and only the second kind is allowed to ask — or to destroy.

## The rule

**Presentation or process.** Every command in fyolo acts on one or the other,
and that decides its key, its confirmation, and whether it may cascade.

- Keys that change presentation — panes, windows, focus, the inspector — never
  end a process. They need no confirmation, because nothing is lost.
- Keys that end a process are few, named, and confirm when there is live work.

⌘Q and ⌘W are both the second kind, at two scales: ⌘Q ends every session, ⌘W ends
the one in front of you. That is the whole design; the rest of this doc is which
object each key acts on, when a process key may ask, and how the neighbours answer
the same question.

This replaces the earlier "fyolo is sidebar-shaped, not tab-shaped" framing,
which described a conclusion but couldn't be applied to a key you hadn't already
decided. Presentation-or-process can.

## Which object ⌘W acts on

Every tabbed terminal binds ⌘W to "close the surface", and in those apps the
surface *is* the process — closing it kills the program. fyolo's objects don't
line up one-to-one:

| fyolo | tabbed terminal (iTerm2, Ghostty) |
| --- | --- |
| **Pane** — a view slot in a split group | surface — the process itself |
| **Session** — durable: owns the PTY, a resume id, sometimes a worktree; lives in the sidebar; survives relaunch | (no equivalent) |
| **Split group** — the layout, persisted | tab |
| **Window** — one, always | one of many |

So `close_surface` has two possible readings in fyolo: *remove this pane from the
layout* (Ungroup), or *end this session*. **The session is the one users arrive
expecting** — it is the tab-shaped object here, the thing that appears in the
sidebar, gets named, and is what "close this" means when you look at the screen.
The pane is a layout slot; nobody's ⌘W habit is about layout slots.

The first cut of this doc chose the pane, on the argument that it is the
structurally faithful translation — same "close the thing in front", no smuggled
process kill. That reasoning holds and was still the wrong trade: it optimised for
what the key *doesn't* destroy at the cost of what the key *is for*, and left the
verb people actually wanted — Close Session — with no key at all
([#242 follow-up](https://github.com/fl0wo/fyolo/issues/242)).

What has to stay true is the part #242 was really about. That bug was not "⌘W
killed a session"; it was ⌘W closing the single window, the app terminating with
it, and **every** agent dying at once with no confirmation. The app now outlives
its window, so ⌘W's blast radius is one session, chosen deliberately, with the
confirmation policy below deciding whether it asks first.

## The map

| Key | Action | Kind |
| --- | --- | --- |
| ⌘W | End the focused session; with no session left, close the window; in an auxiliary window, close that window; with the palette up, dismiss it | process |
| ⌘⇧W | Close the frontmost window | presentation |
| *(unbound)* | Ungroup the focused pane — the session keeps running | presentation |
| ⌘M | Minimize the frontmost window | presentation |
| ⌘D / ⌘⇧D | Split right / down | presentation |
| ⌥⌘ arrows | Focus pane by direction | presentation |
| ⌘⇧↩ | Zoom split | presentation |
| ⌘⇧[ / ⌘⇧] | Previous / next session | presentation |
| ⌃⌘F | Toggle full screen | presentation |
| ⌘T / ⌘N | New Terminal / New Chat | creation |
| ⌘Q | Quit — **confirms** when any session is working or needs you | process |

Closing the window keeps the app running with every session alive; the Dock icon
brings the window back. ⌘W ends the one session it is aimed at; only ⌘Q reaches
the teardown that kills every PTY at once.

The last-session fallthrough is Chrome's: when there is nothing left to close, the
key closes the window rather than going inert. Close Session therefore stays
*enabled* in the menu with no session selected — a dimmed item would swallow ⌘W
before the fallthrough could run.

Window-scoped commands resolve the **key window**, so ⌘W and ⌘⇧W close Settings
when Settings is in front rather than reaching past it to the terminal behind.
With no window on screen, ⌘W does nothing rather than mutating an invisible
layout.

## Confirmation policy

A confirmation is a tax on every correct use of a key, levied to prevent the
rare wrong one. It is worth paying only where the action destroys something
unrecoverable, which is why the policy is keyed on **what would be lost**, not on
how alarming the command sounds:

- **⌘Q** confirms when a session is `working` or `needs-you`. An all-idle app
  quits without a word.
- **⌘W / Close Session** confirms only for a plain shell with a command running in
  front of it — the iTerm2 carve-out. Agent sessions close without a word.
- **⌘⇧W** never confirms, because closing the window destroys nothing.

Every one of these dialogs takes **Return to confirm and Escape to cancel**, with the
destructive button added first so it is the default and the initial first responder
(`FyoloStore.applyConfirmationKeys`). Ghostty puts Return on Cancel and cmux puts it
on Confirm; the reasoning for following cmux is under *Ghostty* below.

That carve-out is what made ⌘W = Close Session viable at all. Under the *first*
confirmation rule — ask whenever the PTY is alive — this binding would have put a
dialog in front of nearly every press, and a dialog that always fires is one people
dismiss reflexively. Relaxing the rule to "what would be lost" came first; the
binding only became affordable afterwards. If the confirmation rule is ever
tightened back, this binding has to be reconsidered with it.

The first cut of this rule confirmed whenever the session's PTY was alive, and
that shipped. It was wrong for a reason worth recording: an agent session's PTY
is alive from the moment it opens until the moment it closes, so "confirm on a
live PTY" is not a rule about live work at all — it fires on **every** close of
**every** agent session. That is the tax paragraph above describing itself. What
it was protecting is weaker than the dialog claimed, too: an agent conversation
is on disk and resumes, while a command typed into a shell has no other record.

Two traps found while building this, kept because they still bound the design:

1. **Attention status is not process safety.** Keying the confirmation off
   `working` / `needs-you` looks right and is wrong: a `done` or `idle` agent
   still holds an entire conversation, and merely *looking* at a session settles
   it back to `idle`. Status can't carry a safety decision — part of why the
   answer for agent sessions is not to ask at all.
2. **A live agent looks idle to the kernel.** `tcgetpgrp` on the PTY master
   reports the foreground process group, which is how iTerm2 decides whether a
   pane is busy. A running `claude` shares the shell's process group, so that
   check reports *no foreground job* for a live agent — verified. The shell
   carve-out is therefore keyed on `agent.isShell` first and the kernel probe
   second, so an agent that *does* fork a child still never prompts.

## How the neighbours answer this

### cmux — the same category

cmux is a Ghostty-based macOS terminal for coding agents, and the closest
comparison. Its published shortcut table and changelog (2026-02-09):

| Key | cmux |
| --- | --- |
| ⌘W | **Close Tab** — closes the focused tab; if it's the last tab, closes the workspace/window |
| ⌘⇧W | Close Workspace (with a confirmation dialog) |
| ⌃⌘W | Close Window (with a confirmation dialog) |
| Return | confirms the close dialog; Escape cancels |

cmux lets ⌘W cascade all the way up to closing the window, and gates the cascade
with a confirmation — plus a separate "running process" dialog. It also enforces
the routing with a CI lint and a review-bot rule whose stated purpose is that ⌘W
must close the active window "instead of falling through to workspace panel
closing." They care enough about this one key to gate it in CI.

**The confirmation keys are the part worth copying, and this doc had them wrong.**
An earlier revision of this table recorded cmux as binding ⌘D to confirm, the macOS
"Don't Save" mnemonic. cmux did ship exactly that, in
[#1219](https://github.com/manaflow-ai/cmux/pull/1219) — and **removed it nine hours
later** in [#1279](https://github.com/manaflow-ai/cmux/pull/1279): the Close button
became the default and the initial first responder so **Return confirms**, the custom
⌘D was deleted, and an XCUITest was added so it can't drift back. Their quit
confirmation (`QuitConfirmationAlertPresenter`) is built the same way — Quit added
first so Return quits — plus a "Don't warn again for Cmd+Q" suppression checkbox.
Checked against cmux `main`, 2026-08-25.

**Where fyolo differs:** the cascade is the same shape — close the focused thing,
fall through to the window when nothing is left — but the dialogs aren't. cmux
gates the cascade with a confirmation and adds a separate running-process one;
fyolo asks only for a shell with a live command, and never for the window close,
because closing the window destroys nothing here.

### Zed — the same object problem, solved by context

Zed's `default-macos.json` resolves ⌘W per context:

| Context | Binding |
| --- | --- |
| `Pane` | `pane::CloseActiveItem` |
| `Workspace` | `workspace::CloseActiveDock` |
| `SettingsWindow` | `workspace::CloseWindow` |
| global | ⌘⇧W `CloseWindow`, ⌘M `Minimize`, ⌘Q `Quit` |

Zed is the closest structural match: a durable object list on the side, panes as
views, and ⌘W closing the *item* while the file stays on disk. Two things
transfer directly. First, ⌘W in an auxiliary window means Close Window — the
key-window routing fyolo now implements. Second, `confirm_quit` defaults to
**false**: Zed doesn't need a quit confirmation because quitting an editor
destroys nothing recoverable.

That last point is the sharpest contrast in this doc. fyolo confirms on ⌘Q for
exactly the reason Zed doesn't: quitting fyolo kills live processes that no
autosave can bring back.

### Ghostty — the same confirmation policy, a different probe

Ghostty's `confirm-close-surface` defaults to `true`, documented as: confirm before
closing a surface, *"even if shell integration says a process isn't running"* only
when set to `always`. So its default is already "ask only when something is
running" — the same policy as fyolo's Close Session, reached independently.

The difference is the liveness probe. Ghostty asks the **shell** (OSC 133 command
marks, via shell integration); fyolo asks the **kernel** (`tcgetpgrp` on the PTY
master), and only for a session whose declared agent is a shell. Ghostty's signal
is the more general one, but it depends on shell integration being installed and
emitting marks; fyolo's works regardless of the user's shell config, at the cost
of saying nothing about an agent — which fyolo answers by not asking for agent
sessions at all.

Its close dialog defaults focus to **Cancel**, so Return cancels. fyolo shipped that
too, and **no longer does** — this is the one place the neighbours split, so the
disagreement is worth stating rather than averaging away:

- **Ghostty:** Return cancels. Its dialog is raised by `confirm-close-surface` on a
  key the user may not have meant to press, and the surface is one shell.
- **cmux:** Return confirms, on both the close dialog and the quit sheet, enforced
  by a UI test after they tried the Cancel-default design and dropped it same-day.
- **herdr:** doesn't ask at all — closing a pane kills it and its process with no
  prompt. A built-in `confirm_close_tab` is an open request
  ([discussion #648](https://github.com/ogulcancelik/herdr/discussions/648)); the
  community plugin that fills the gap uses tmux's `y`/Escape, so Return isn't a
  confirm key there either — but it's a TUI, where Return can't be one.

fyolo follows cmux, for the reason its own reversal makes plain: this dialog only
appears after the user pressed ⌘W or ⌘Q **on purpose**, and a confirmation whose
"yes" the keyboard cannot reach isn't cautious, it's a dead end you have to take
your hands off the keys to answer. So Return confirms, Escape cancels, and the
destructive button still draws destructive. What survives from the Ghostty reading
is the part that was actually load-bearing: **the dialog must be rare.** It fires
only for a plain shell with a live foreground job, never for an agent session — see
*Confirmation policy* above. A dialog that fires constantly is the failure mode; a
dialog you can answer with Return is not.

Ghostty users push back on that dialog even at its lower frequency —
[#9669](https://github.com/ghostty-org/ghostty/discussions/9669) asks for a
`force_close_surface` action to bypass it,
[#7357](https://github.com/ghostty-org/ghostty/discussions/7357) asks how to
remove it entirely. A confirmation that fires constantly becomes something users
engineer their way around; that is why the prompt stays off ⌘W, and why the
version of Close Session that asked on every agent close didn't survive first
contact with using it.

### Raycast — the command layer, not the window layer

Raycast isn't a window app in this sense, and it's closed-source, so it belongs
here for a different reason: its **command layer**. Every command is an object in
one searchable root, with an optional per-command hotkey and alias, and a
contextual action panel on ⌘K. Almost nothing is bound by default; discovery
carries the long tail and the user promotes what they use.

fyolo's equivalent is already in place: `KeyCommandCatalog` is the single source
of truth for every rebindable command, the ⌘⇧P palette searches it, Settings ▸
Keyboard rebinds it, and the surface's ghostty unbind set is *derived* from it so
a rebind can't be swallowed by the terminal. The lesson taken from Raycast is
restraint — a command earns a default key by being pressed constantly, not by
existing. Split Left, Split Up, and Ungroup ship unbound for this reason.

## Resolution: one action that branches, not a context tree

Every tool above resolves a key **declaratively by context**. Zed's rule is
explicit:

> Bindings that match on lower nodes in the context tree win. […] If there are
> multiple bindings that match at the same level in the tree, then the binding
> defined later takes precedence.

VS Code says the same thing with `when` clauses. fyolo does not: `KeyCommandCatalog`
is a flat table, and ⌘W resolves itself *imperatively*, inside one action — is the
key window an auxiliary one, is a session selected, otherwise close the window.

At this size that is the simpler design, and it stays honest because there is
exactly one place to read. It is deliberate, not an oversight — but it only earns
that defence if the decision is *isolated and tested*, because this is the binding
that regresses silently: the window still closes, just the wrong one — and now that
the key ends a process, a regression can also end the wrong session. cmux guards
the same key with a CI lint. fyolo's equivalent is `CloseCommand.action`, a pure
function over "what is in front" × "is a session selected", with
`CloseCommandTests` pinning every combination.

Keeping the decision pure also made a case visible that the imperative version had
wrong: the ⌘⇧P palette is a **borderless** panel, and `performClose` on a window
with no close button only beeps. Routing it to the store flag that owns the
palette's presentation turns a dead key into a dismiss.

The known cost shows up one layer in: with a diff or editor detail open in the
inspector, ⌘W closes the session instead of the detail. Zed would close the detail —
its `Workspace` context binds ⌘W to `CloseActiveDock`.

That symptom is **not** fixed by adding another branch. Zed's dock binding matches
only when focus is *in* the dock; fyolo has no focus notion for the inspector, so
"close the detail whenever one is open" would break the common case — a diff open
beside a terminal you are typing in. Doing it correctly needs a focus/context
notion, which is the refactor, not a patch.

**The trigger to build contexts:** when a third state needs its own answer for the
same key, or when a binding's correctness depends on which region has focus. Until
then, branch and keep it in one function.

## Reversed

- **⌘W = Ungroup** shipped from 2026-08-12 to 2026-08-25, then lost the key to
  Close Session — the literal iTerm2/Ghostty reading and the original
  recommendation in [#204](https://github.com/fl0wo/fyolo/issues/204),
  arrived at a second time by the browser route: ⌘W closes a tab, and the
  tab-shaped object here is the session.

  The argument that had rejected it was that its running-job prompt would fire on
  nearly every press, since `working` is an agent's normal state. That objection
  died with the confirmation rewrite in this doc's own *Confirmation policy*
  section: agent sessions don't prompt at all, so the dialog is now rare enough
  that the binding costs nothing it used to. Ungroup keeps the menu verb.

  **The cost, recorded so it isn't rediscovered as a surprise:** ⌘W now ends an
  agent session with no dialog and no undo. Chrome has ⌘⇧T; fyolo has nothing
  that reopens a closed session. If that becomes the complaint, the answer is a
  reopen, not a confirmation — a dialog on every press is the failure mode this
  doc already has a section about.

## Rejected

- **⌘1…⌘9 to select the Nth session.** Ghostty's `goto_tab` and the
  Safari/Chrome convention, but there is no stable Nth: with `recentActivity`
  sorting, selecting a session reorders the tree, so pressing ⌘4 changes what ⌘1
  means. Positional keys need explicit user-assigned slots, not a live tree.
- **⌥⌘W = Ungroup All.** Mirrors Ghostty's `close_tab:this` positionally, but
  that binding is destructive and dissolving a split group is not, so it would
  mislead both audiences. Ungroup All stays a menu verb.

## Deferred

Tracked in [#204](https://github.com/fl0wo/fyolo/issues/204):

- The ghostty-defaults fixture test, so a libghostty bump that adds a default
  binding breaks the build instead of silently shadowing an app key.
- ⌘[ / ⌘] for previous/next pane — redundant with ⌥⌘ arrows; wait for demand.
- ⌃⌘ arrows to resize the divider and ⌃⌘= to equalize. Blocked on defining which
  divider moves when the focused pane touches several ancestors; the binding is
  easy, the rule isn't.
- A focus/context notion for key resolution, and with it ⌘W closing a focused
  inspector detail. See *Resolution* above for the trigger.
