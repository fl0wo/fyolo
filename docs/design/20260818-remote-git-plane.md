---
title: Remote git — the pane's verbs run on the device
status: done
type: rfc
created: 2026-08-18
updated: 2026-08-31
related:
  - 20260818-one-workspace-source.md
  - 20260818-one-workspace-source.review-codex.md
  - 20260803-agent-permission-questions.md
  - 20260805-fyolod-device-architecture.md
  - 20260730-fyolod-session-protocol.md
---

# Remote git — the pane's verbs run on the device

> Give the Changes pane a full git plane on another machine, following Zed's
> remote-server design: git runs on the box with that box's credentials and
> config, and the prompts it raises are forwarded to the client rather than
> answered by fyolo.

## 1. Decision

The git plane stops being read-only. `fyolod/src/git.rs:5-7` currently states
the opposite — "Read-only by design: no stage/commit/push verbs, the user
commits in the terminal, which is the same app" — and this RFC retires that
sentence.

The argument that retired it: the objection to remote write verbs was that
`push`, `pull`, and `commit` need credentials and signing keys, and routing
those through fyolo would brush non-negotiable 3. **Zed already solved this,
and the solution embeds nothing.** §3 is the mechanism. Once prompt-forwarding
is the design, the credential objection does not survive, and what remains is a
pure product question — which the project rule about the git pane already
answers (§4).

Note the stated position was also only half-true. The shipped pane already
mutates: Discard (`GitChangesView.swift:441` → `GitService.discard`,
`GitService.swift:80`) and Ignore (`GitChangesView.swift:360,381` →
`appendToGitignore`, `:584`). So the choice was never read-only versus
read-write; it was two undocumented mutations versus a designed set.

## 2. What exists today

**On the device.** Two things, both read-only:

| Piece | Where | Shape |
| --- | --- | --- |
| `git:` resource | `git.rs:132` (`run_status`), `:66` (`delta_from`), `:44` (`full_batch`) | Subscription. Debounced `git status --porcelain=v2` when the workspace watcher fires; publishes the delta, synthesizes a full batch on gap. Carries statuses, branch, head, ahead/behind, conflicts |
| `GitDiff` | `protocol.rs:535`, `git.rs:289` | `git --no-optional-locks -C <root> diff [--cached] -- <path>`. Unified text, capped at `DIFF_CAP` = 1 MiB (`git.rs:16`) with a `truncated` flag |

**In the client.** `GitService` runs `/usr/bin/git` locally and backs the whole
pane. The verbs with no device counterpart:

| Client verb | Where | Pane surface |
| --- | --- | --- |
| `log` | `GitService.swift:107` | History tab |
| `compareContext`, `branchCompare` | `:237`, `:242` | Compare tab |
| `discard` | `:80` | Discard action |
| `appendToGitignore` | `:584` | Ignore action |

`diffText` (`:67`) already returns diff *text*, and `DiffDocument` /
`DiffTextView` / `DiffHighlighter` consume text — so the diff **rendering** is a
provider swap, not a redesign.

## 3. The mechanism: forward the prompt, never the credential

Zed's remote server runs git as an ordinary child process on the remote box.
That process uses the box's own credential helper, `user.signingkey`, hooks, and
`~/.gitconfig`. Nothing about auth is reimplemented. When git needs a human, the
prompt is forwarded (`crates/git/src/repository.rs:3949-3951`):

```rust
.env("GIT_ASKPASS", ask_pass.script_path())
.env("SSH_ASKPASS", ask_pass.script_path())
.env("SSH_ASKPASS_REQUIRE", "force");
```

Three details carry the design:

1. **`GIT_ASKPASS` and `SSH_ASKPASS` point at the same script.** The first
   serves HTTPS credential prompts, the second SSH key passphrases.
2. **`SSH_ASKPASS_REQUIRE=force`** is what makes it work at all on a remote
   box: it forces ssh to use askpass *even with no TTY and no `DISPLAY`*. Without
   it, a passphrase prompt on a daemon-spawned child simply fails or hangs.
3. **The script talks back over a Unix socket.** Zed generates a small
   `askpass.sh` in a temp dir and passes the socket path by env var
   (`crates/askpass/src/askpass.rs:30-37`, `:119`, `:225`, `:241-260`). On a
   remote server the askpass program defaults to the server executable itself,
   so no extra binary ships.

Zed also sets `GIT_ASKPASS=false` for operations that must never block
(`repository.rs:4290`), so a non-interactive path fails fast instead of hanging.
Adopt that too.

**Why this does not violate non-negotiable 3.** fyolo implements no
authentication, stores no credential, and reads no key. It transports a question
and an answer. This is the posture the project already takes for ssh itself, and
Zed's remote docs state the same: SSH's prompts are shown in the UI.

**Prior art in this repo, cited honestly.**
`20260803-agent-permission-questions.md` is an agent permission prompt
forwarded from a session to the phone and answered there. Its status is "built,
measured, shelved" — the mechanism was proven end-to-end and then shelved for
lack of evidence about who wanted it, not because it failed. An askpass prompt
is the same object shape: a typed question raised on the box, answered by a
client. That document is a design input, **not** a shipped dependency, and this
RFC must not assume its code is live.

## 4. Zed's mechanism, GitHub Desktop's surface

Zed's `crates/proto/proto/git.proto` is roughly 60 messages: `Stage`, `Unstage`,
`Commit`, `Push`, `Pull`, `Fetch`, `GitReset`, `GitCheckoutFiles`, the `Stash`
family, branch create/change/rename/delete, `GitCreateRemote`/`GitRemoveRemote`,
`GitShow`, `LoadCommitDiff`, `BlameBuffer`, `CheckForPushedCommits`,
`GetPermalinkToLine`, `GitInit`, `GitClone`, `SetIndexText`.

That size is honest for Zed — their git panel is the *only* git interface for a
remote project. It is not the right size here. **Take Zed's transport and
askpass design; keep GitHub Desktop's vocabulary**, per the standing project
rule that the git pane copies GitHub Desktop. Verbs Zed has that GitHub Desktop
does not expose (`GitInit`, `GitClone`, `SetIndexText`, remote add/remove) stay
out until a pane surface asks for them.

| Tier | Verbs | Prompts | Network |
| --- | --- | --- | --- |
| **1 — Read** | `git.log`, `git.show` (+ commit diff), `git.branches`, `git.blame` | No | No |
| **2 — Local mutation** | `git.stage`, `git.unstage`, `git.commit`, `git.discard`, `git.stash` / `pop` / `apply` / `drop`, branch create / switch / rename / delete, `git.ignore` | No | No |
| **3 — Network** | `git.push`, `git.pull`, `git.fetch` | **Yes** | Yes |

Plus the askpass channel itself: a prompt **event** carrying the text and a
request id, an **answer** verb, and Zed's two non-answer outcomes —
`CancelledByUser` and `Timedout` (`askpass.rs:39-43`) — so a prompt nobody
answers cannot wedge the pane. It rides the existing `Cancel { request }`
mechanism (`protocol.rs`), not a new one.

## 5. Staging

Ordered by what a pane does better than the shell that is already open beside
it, so each stage is worth shipping alone.

### Stage 1 — Read tier

`git.log`, `git.show` + commit diff, `git.branches`, `git.blame`. Nothing here
can prompt, nothing needs the network, and it fills the History and Compare tabs
that the workspace-source review flagged as unbacked
(`20260818-one-workspace-source.review-codex.md`, "Search, Changes, and Issues have no
staging").

Biggest win per verb: a scrollable commit list with diffs beats `git log -p` in
a pager, which is the case where a pane genuinely beats a terminal.

*Gate:* History and Compare render for a device workspace with the same views
they use locally, and every unsupported control is hidden rather than inert.

### Stage 2 — Local mutation tier

Staging, commit, discard, stash, branch operations, ignore. No network, no
credentials, so no askpass dependency. This is GitHub Desktop parity and it
retires the `git.rs:5-7` sentence.

Commit runs the box's hooks, which is the point — but hook output and hook
failure must reach the pane, not be swallowed into a generic error.

*Gate:* commit on the device with a failing `pre-commit` hook shows the hook's
own output. Concurrent `index.lock` contention with the terminal is reported as
such (§7.1).

### Stage 3 — Askpass channel

Built and tested **alone**, before any verb depends on it: a passphrase-protected
SSH key, a prompt raised on the box, answered on the Mac, plus the cancel and
timeout paths.

*Gate:* `ssh-add`-less clone over SSH with a passphrase-protected key completes
after answering on the Mac; cancelling produces a named error, not a hang; a
prompt left unanswered times out and releases the request.

### Stage 4 — Network tier

`git.push`, `git.pull`, `git.fetch`, depending on Stage 3. Long-running and
cancellable, with progress surfaced (§7.2).

*Gate:* push to a repo requiring credentials succeeds; the same push with
`GIT_ASKPASS=false` semantics fails fast with a named error instead of hanging.

## 6. Where this goes past Zed

The askpass prompt is a typed object on a protocol that multiple clients already
attach to. So the answer need not come from the Mac that started the operation —
it can come from the phone, which is exactly the shape
`20260803-agent-permission-questions.md` built and proved.

Zed cannot do this: their askpass socket is local to the client process that
spawned the child. Here the prompt is a protocol event, and the device may have
several attached viewers.

This is a **consequence** of the design, not extra work, and it should not be
built in Stage 3. Stage 3 ships Mac-answered prompts; phone-answered prompts are
a later, small increment — and per the shelved doc, one that should be measured
before it is built again.

## 7. Known hard parts

### 7.1 Index lock contention

The agent in the terminal and the pane now both run git against one checkout.
`git status` already passes `--no-optional-locks` (`git.rs:291`), but `git add`
and `git commit` take `index.lock`, and an agent mid-commit will make a pane
commit fail.

This must be a named, retryable error with the competing operation identified,
never a generic failure and never a silent retry loop. Decide whether the daemon
serializes mutating git verbs per workspace root.

### 7.2 Long operations need progress and cancellation

A push or fetch on a large repo is not a request/response. Zed carries
`RemoteMessageResponse` for this. Stream progress as events tagged with the
request id — the same shape `fs.search` already uses — and make cancel actually
kill the child, not just detach the reply.

### 7.3 GPG signing is not covered by askpass

`GIT_ASKPASS` does not reach gpg. A passphrase-protected GPG key prompts through
gpg-agent/pinentry, which on a TTY-less child can stall. SSH signing
(`gpg.format = ssh`) *does* route through `SSH_ASKPASS` and works.

This is inherent to gpg and Zed has the same edge. Requirement: Stage 2 detects a
signing failure and names which case was hit, rather than reporting a generic
commit error.

### 7.4 The prompt text is untrusted input

The prompt string originates on the remote box. A compromised or hostile host
could craft text that reads like a fyolo system dialog and phish a credential.
The client must render it as remote, attributed, untrusted text — never as
chrome that looks like fyolo asking.

### 7.5 Secret handling

Copy Zed's posture: the answer is a distinct type, not a `String` passed around
(`askpass.rs:3`, `EncryptedPassword` with an intentionally awkward escape hatch).
Never log it, never persist it, never include it in an error or a trace.

### 7.6 Multi-repo workspaces

Zed carries `UpdateRepository` / `RemoveRepository` because a project may hold
several repositories. fyolo's pane assumes one `repoRoot`. This RFC assumes one
repository per workspace and says so; multi-repo is out of scope.

## 8. Prerequisites

1. **The workspace reference.** Every verb here needs a `(device, root)`. That
   decision is unresolved in `20260818-one-workspace-source.md` and its review; a `.host`
   container cannot supply it, because `hostContainer` keeps one root per alias
   with first-writer-wins. **This RFC is blocked on that decision** and should
   not be implemented before it.
2. **Connection ownership.** The review requires a durable per-device connection
   before resource subscriptions; the `git:` subscription is a resource
   subscription. Same prerequisite, same reason.
3. **Capability negotiation.** The `git:` resource requires `resources` (and the
   `git` capability for `git.diff`). Capabilities are fixed at `hello`, so the
   channel serving files and git must negotiate all of them or reopen.

## 9. Open questions

1. Does the daemon serialize mutating git verbs per workspace root, or report
   lock contention and let the client retry? (§7.1)
2. Is the askpass channel a general prompt plane — reusable by the agent
   permission work and anything else on the box that needs a human — or is it
   git-specific? A general one is more useful and harder to get right.
3. What is the timeout for an unanswered prompt, and what happens to the git
   child when it fires? Zed has `Timedout` but the policy behind it needs
   stating here.
4. Does Compare need `branchCompare` device-side, or can it be composed from
   `git.log` plus `git.diff` without a new verb?
5. Blame is editor-adjacent and fyolo's editor is a preview. Does it belong in
   Stage 1 at all, or wait for a real editor surface?

## 10. Non-goals

- No credential storage, no key handling, no auth implementation. Prompts are
  forwarded; that is the entire security posture.
- No verbs GitHub Desktop does not expose: `GitInit`, `GitClone`,
  `SetIndexText`, remote add/remove.
- No multi-repository workspaces (§7.6).
- No new transport. These verbs ride the existing framed protocol.
- No GitHub/forge API work. Issues and PRs are a separate pane with a separate
  gap (device-owned repository identity), tracked in the workspace-source review.
