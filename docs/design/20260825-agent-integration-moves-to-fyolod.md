---
title: Agent integration moves into fyolod
status: active
type: rfc
created: 2026-08-25
updated: 2026-08-26
related:
  - 20260824-agent-integration-on-a-device.md
  - 20260819-unify-server-plane.md
  - 20260817-one-path-local-through-fyolod.md
  - 20260824-ios-as-device-client.md
  - 20260718-agent-abstraction-and-configuration.md
---

# Agent integration moves into fyolod

> The machine that owns the files decides what goes in them. `AgentCatalog` and
> both installers move to Rust, and Swift asks for an install instead of
> performing one — reversing §D5 of the device RFC, and settling which of two
> active documents was right.

## The contradiction this settles

Two live documents disagree, and the disagreement is load-bearing:

- [`20260824-agent-integration-on-a-device.md`](20260824-agent-integration-on-a-device.md)
  **§D5** — "The daemon never learns what an agent is, where `.claude` lives, or
  which agents are enabled. It answers *write these bytes under `$HOME`, safely*
  and nothing more. `AgentCatalog` — including user-authored agents with their own
  `skills` declaration — stays in Swift, one implementation."
- [`20260819-unify-server-plane.md`](20260819-unify-server-plane.md) **Stage 10** —
  the CLI moves verb by verb, ending with "`agent report` → `set-status` plus
  **hook installation on the device**."

D5 is the newer document and the narrower claim, so it has been the one in force.
This RFC reverses it. Stage 10 was right.

## Why D5 loses

D5's argument was about **duplication**: four hook dialects, the conflict
fingerprints and the refusal rules would have to exist in Rust as well as Swift,
and the catalog they read is user-extensible — a user drops a JSON manifest in
`AgentCatalog.userAgentsDirectory` and it becomes a real agent. That cost is real
and this RFC pays it rather than denies it.

What D5 did not price is the shape it forces. Policy in Swift and files on another
machine means **the plan and the filesystem are on opposite ends of a network**,
and every step of the plan is a question that has to cross it:

| | |
| --- | --- |
| Hook install, per agent | `exists` + `read` + `write` |
| Skill install, per agent | `isCommandInstalled` + `read` + `write` |
| A twelve-agent box | **40–60 sequential `ssh` invocations** |

Each is a `Process` with `waitUntilExit()`. Run from the button handler, that was
a beachball — the window stopped drawing until the last write returned. That has
been fixed by making the install `async`, which is the correct fix for *freezing*
and does nothing for the round trips: the install is still one blocking
conversation per file, and on a link with 200 ms of latency it is tens of seconds
of spinner.

Batching would cut it to two round trips — read everything, merge in Swift, write
everything with `expect_sha256` preconditions — and it is a genuinely good
intermediate step. But it is a workaround for the split, not a fix: it needs a
batch read and a batch write on the transfer plane that do not exist
(§D3's `home:` dest is unbuilt), it keeps two implementations of *reachability*
(the SSH arm and the protocol arm), and it leaves the phone and the browser unable
to install anything at all, because both lack the Swift that holds the policy.

The deciding argument is the one Stage 10 already made: **the machine that owns
the files is the machine that should decide what goes in them.** An install is a
local operation that has been performed remotely by accident of where the code
lives.

## What moves

| Swift today | Lines | Goes to Rust |
| --- | --- | --- |
| `AgentDefinition.swift` — manifest schema, `AgentCatalog`, bundled + user manifests | 1308 | The catalog and the schema. |
| `HookListener.swift` — six dialect writers, conflict fingerprints, refusal rules | 1134 | The installers. **Not** the listener half — the socket that receives reports stays where the app is. |
| `SessionControl.swift` — skill installer, skill payload selection | 1031 | The installer and both payloads. |
| `AgentConfigStore.swift` — the local/SSH seam | 486 | **Deleted.** Its whole reason was that the writer was on the wrong machine. |
| `InstallOutcome.swift` | 35 | Becomes a protocol reply. |

The 15 bundled manifests under `Sources/fyolo/Resources/agents/` become a
fyolod resource. The user's own manifests stay exactly where they are, in the
same format — that is the compatibility line this must not cross.

## What Swift keeps

Everything that is a **preference** rather than a fact about a machine:

- which agents are on the user's list, and in what order
- the default New Chat agent
- whether live status and session control are wanted at all
- the per-device command path override

Swift's call becomes one message — *install the integration for this set of
enabled agents* — and one reply. `AgentSettingsTab` and `DevicePane` lose their
`Task.detached` wrappers because there is nothing left to detach.

## The cost, stated plainly

**A second parser for a user-extensible format.** Rust must read the same manifest
JSON Swift reads, and a manifest the two disagree about is a bug the user sees as
"my agent works in the list but gets no hooks". Mitigation: the schema is data,
not behaviour — one set of fixture manifests, parsed by both, asserted equal. That
test is the contract, and it belongs in CI from the first stage.

**Swift does not stop parsing manifests.** It still renders the roster, so it
still needs names, icons and commands. What it stops doing is *writing* from them.
The duplication is therefore in the schema, not in the dialects — which is the
smaller half, and the half that changes rarely.

**A local install becomes an IPC call.** On this Mac the installers currently run
in-process. After this they go through fyolod like everything else, which is
[`one-path-local-through-fyolod`](20260817-one-path-local-through-fyolod.md)'s
whole thesis and not a new cost.

## Stages

Ordered so each one is shippable and none is a big-bang.

Stages 1 through 4 are delivered; what each one actually cost and caught is
recorded below the table, because a stage list that only says *done* is how the
device RFC's own table came to mislead a reader into re-deciding something that
had already shipped.

| Stage | Deliverable | Gate | State |
| --- | --- | --- | --- |
| **1** | Manifest schema in Rust, parsing the same 15 bundled files plus the user directory. Nothing installs yet. | A fixture test parses every manifest in both languages and asserts the same values. | **Done** #461 |
| **2** | The two shell-command dialects (JSON manifest, script directory) and the skill installer, behind a new `install` control message. | Installing on `ukvps` through fyolod produces byte-identical files to the SSH arm's output. | **Done** #461 |
| **3** | The plugin dialects and the TOML block. | Same byte-identical gate, all six dialects. | **Done** #465 |
| **4** | Swift calls it. `AgentConfigStore` and `SSHAgentConfigStore` are deleted; `DevicePaneModel.setUp` becomes one call. | A twelve-agent install is one round trip. The Settings surfaces are unchanged. | **Done** #472 |
| **3.5** | A per-agent config-home variable (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, …), inserted before Stage 4 so the schema changed once rather than twice. | Six of fifteen agents have a documented one; OpenCode does **not** — `OPENCODE_CONFIG_DIR` adds a search directory rather than moving the config home, so installing under XDG is still always read. | **Done** #467 |
| **5** | The phone installs. | The iOS device client offers Set up on a directly-attached box, with the Mac quit. | Blocked on P0.2 — PR #344 |
| **6** | One report path. `SetStatus` grows the four fields only the local socket carried, then every hook reports to the daemon that owns its PTY and the app becomes a viewer of status rather than its receiver. `HookReporter` and the app's `agent-status.sock` are deleted. | A Mac-local agent still carries transcript, conversation, tool and prompt title — *and a device agent on `ukvps` now carries them too*. | 

### What the stages actually cost, and what they caught

The round trips were worse than the estimate this RFC was written on. Measured by
counting `ssh` invocations against a twelve-agent box:

| | before | after |
| --- | --- | --- |
| install | **98** | 1 |
| probe | **45** | 1 |

Three defects surfaced that no amount of reading would have found, each of them
silent because every hook form ends in `2>/dev/null || true`:

- **The SSH arm could not recognise its own device hooks.** ` agent report ` and
  `agent-status.sock` were the only ownership fingerprints, and a device hook
  invokes `fyolod set-status`. Every reinstall appended a second copy of every
  entry; `ukvps` had accumulated 54 duplicate hook lines. Fixed in #463, and the
  daemon spells the fingerprint identically (`DAEMON_MARKER`).
- **`report_command` read `capturesTranscript` off any manifest**, so a scripts or
  TOML agent would have been handed `--transcript` and blocked waiting on stdin
  that never arrives. Every *bundled* manifest happened to produce the right bytes,
  so the byte-identical gate could not have caught it — only a user manifest would
  have. This is the user-extensible-format risk this RFC accepted, arriving for
  the first time.
- **The daemon binary was a guess.** `$HOME/.local/bin/fyolod` is where the Mac
  assumed a deploy put it; a box keeping it elsewhere got a plugin that exec'd a
  file that was not there. The daemon resolves `current_exe()` instead.

Stage 4 added one decision worth keeping visible: a device whose daemon is too old
to have the install message is **refused by name, and not redeployed**. Redeploying
restarts the daemon, which kills its running sessions — `ukvps` had 15.

Stage 6 comes after 4 for a reason that is not sequencing convenience. Stage 4
moved who *writes* a hook; Stage 6 moves who the hook *reports to*, and doing
the second before growing `SetStatus` would be a downgrade: the Info pane would
lose the transcript path, a `/new` rotation would stop being followed, and the
sidebar would stop knowing which tool is running. Grown first and switched
second, the asymmetry between a local agent and a device one dies from the poor
end rising.

What Stage 6 does **not** move is the screen-derived half — the stale-working
streak promotion and the `OSC 0/2` title classification. Those read a VT, and
the VT for a device is the daemon's while the VT for this Mac is the app's own
surface. They are the only status signal an agent with no hook system has, and
they stay until [`unify-server-plane`](20260819-unify-server-plane.md) moves the
VT itself.

Stages 1–4 depend on nothing in the iOS work. Stage 5 depends on
[`ios-as-device-client`](20260824-ios-as-device-client.md) P4, which depends on
P0.2 — `fyolod serve --wss`, currently PR #344 with failing CI.

## Non-goals

- **The hook listener does not move.** `agent-status.sock` receives reports for an
  app to render; the daemon already has `set-status` for the device case.
- **No new transfer-plane work.** §D3's `home:` dest and §D4's `expect_sha256`
  were the shape needed to write files *from* the client. With the writer on the
  box, neither is required for this — D4's precondition remains correct for the
  SSH arm until Stage 4 deletes it.
- **The user manifest format does not change.** A format migration and a language
  migration at once is how both fail.
