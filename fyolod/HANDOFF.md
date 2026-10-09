# fyolod v1 — Handoff for the next orchestrating agent

You are taking over an in-progress effort on **fyolod**, fyolo's durable PTY
session host. Your job is to keep **orchestrating sibling agents** (Codex, other
Claude sessions) to build out **v1** — the authoritative-VT snapshot layer
(issue #181) — while preserving the architecture and discipline established so
far. Read this whole file before dispatching anyone.

- **Branch / PR:** everything lives on `fyolod/rust-poc` (draft PR **#177**).
  Tip at handoff: **`1aa8d23`**. Worktree:
  `/Users/yuanjiwei/Documents/GitHub/fyolo/.claude/worktrees/fyolod-rust-poc`.
  The main checkout is on `main` and has *unrelated* modified iOS files — **do
  not touch them**; do all fyolod work in the worktree.
- **Epic:** #164. **Done:** #179, #180. **Active:** #181 (spike complete, Phase 1
  next).

---

## 1. What fyolod is (the thesis you must preserve)

`fyolod` is a durable session host: it owns every PTY, and Mac/iOS/CLI/remote
are all **attach clients**. Detach ≠ kill. The design is written up in
`docs/design/20260730-fyolod-session-protocol.md` (the spec) and
`20260730-fyolod-session-mux.md` (product/competitive). Read §A of the protocol doc.

**The one load-bearing idea — input replication, not state sync.** A VT parser
is a deterministic state machine: same bytes in → same screen out. The host
keeps every viewer consistent by **shipping the byte log** (raw PTY bytes teed
to every client, each replays through its own libghostty), *not* by shipping a
server-maintained grid. This is what makes fyolod fast; tmux does the opposite
(parses every byte into a grid) and pays a 16–24× tax (benchmarked, see below).

### Non-negotiable invariants (do not let any agent violate these)

1. **Anti-100× invariant:** *byte delivery MUST NOT block on host-side VT parse.*
   `session.rs::fan_out` is copy/refcount + socket only — it never inspects byte
   contents. The v1 VT is a **sidecar**, consulted only to build snapshots, off
   the hot path. Any per-frame grid encoder between PTY and pipe rebuilds the
   tmux tax and is rejected.
2. **State sync only at boundaries:** the `S` snapshot fires on attach / resize /
   resync (and a periodic keyframe in the v1.1 diff mode) — never per frame.
3. **Wire protocol is transport-agnostic and versioned:** same framed messages
   over Unix socket / SSH / (later) QUIC. Don't change framing without a `proto`
   bump. SSH is the trust plane; QUIC is a later performance plane with borrowed
   identity (no DIY PKI).
4. **Single writer, many readers.** Observers never claim the write token.
5. **No nested window manager** in the host. One PTY per session.

---

## 2. What's already done (with commits, all on `fyolod/rust-poc`)

| Commit | What |
| --- | --- |
| `4ebd51d` | Design reframed as input-replication vs state-sync; anti-100× invariant (§A); `S` snapshot triggers (§C.6) |
| `d568a22` | **Anti-100× benchmark** — `fyolod/bench/bench_100x.py` (+ README). Result: fyolod tee is **4–6× tmux on the Mac, 16–24× on the VPS** (parse tax is CPU-relative — memcpy tee vs CPU-bound parser). tmux loses ~50% plain→ANSI; fyolod holds. |
| `1373646` | Folded in a Codex review vs Mitchell Hashimoto's Superlogical talk: dimension-mismatch correctness req (§C.5), unbounded-backlog (§F #10), resize-barrier (§F #11) |
| `c87a034` | **#180** `bytes::Bytes` zero-copy fan-out + bounded 4 MiB per-client backlog. Kills the (C+2)×n copies AND unbounded memory. Slow clients dropped + logged. |
| `ae6f4f8` | `opt-level=3` re-bench → no material change (confirms hot path is memcpy/syscall-bound, not compute-bound) |
| `75b1e58` | **#179** non-interactive `attach --observe` mode (pure copy-to-stdout, never claims writer, no stdin-EOF exit). Fixes the 0-bytes-over-SSH bug; unblocks scripting + the live backlog-drop test |
| `f677026` | #181 spike: evaluated `alacritty_terminal` vs `libghostty-vt`. Standalone proof `fyolod/spike/vt-sidecar` (alacritty). Report: `docs/design/20260731-fyolod-vt-sidecar-spike.md` |
| `bd1ead5` | Corrected §C.6: libghostty-vt 1.3.2 cells are **opaque** — no wire-ready 16-byte cell; conversion required regardless of engine |
| `5e956aa` | **DECISION:** v1 VT engine = **libghostty-vt** (overrode the spike's alacritty pick) — see §3 |
| `1aa8d23` | **#181 Phase 0 done:** libghostty-vt FFI build proof `fyolod/spike/vt-ffi` — builds, FFIs from Rust, produces the correct snapshot, cross-compiles to aarch64-musl. Verified independently on both Mac and VPS. |
| `bc36438` | **#181 Phase 1a (part 1):** spike promoted to a real `fyolod/vt` library crate (safe `VtTerminal` wrapper, vendored libghostty-vt, dual-target build.rs). |
| `9f539b8` | **#181 Phase 1a done:** per-session VT sidecar thread (in-band FIFO commands — the snapshot request is an exact byte boundary, unit-proven), `S` frame (versioned 16-byte wire cells) + `ready` event, capability-gated with ring-replay fallback; `fan_out` untouched on the hot path. Verified independently: Mac (4+2 tests, 33 local + 8 remote smoke, musl cross-build) and ukvps native (build, tests, 33 smoke). |
| `c3ba217` | **#181 Phase 1b (part 1):** resize is a snapshot barrier — `pty.resize` failure now surfaced (typed `internal` error, dims/events untouched, unit-proven via non-PTY fd); on success the sidecar `Resize` + per-client `Snapshot` requests ride the FIFO adjacently, snapshot clients re-enter `SnapshotPending`; `request_id` versioning drops stale in-flight snapshots (fixes the attach-snapshot × resize race). Decision: **every** successful `S` is followed by `ready`. |
| `74f0c7c` | **#181 Phase 1b (part 2):** writer failover size reclaim — the promoted writer receives `ResizeClaim` naming itself; the reference client answers by re-sending its size as `R`, which triggers the barrier. Verified independently: Mac (5 tests, 38 smoke, 8 remote, musl cross) and ukvps native (5 tests, 38 smoke). **New gotcha:** a daemon auto-started by an earlier smoke run keeps running the OLD binary image — `pkill -x fyolod` before re-running smoke on a rebuilt binary (bit us on ukvps: barrier S never arrived because the live daemon predated the barrier). |
| `cee565e` + `7998539` | **#181 Phase 1c done:** `attached` carries the authoritative PTY `rows`/`cols` (serde-additive, old payloads default 24×80; values taken atomically with registration via `AddClientReply`, emitted before the writer's post-attach resize); observer CLI prints a one-line size-mismatch notice; smoke asserts `attached` dims == `S` header dims. Verified independently: Mac (6 tests, 40 smoke, 8 remote, musl cross) and ukvps native (6 tests, 40 smoke). |
| `c48ff9c` + `476c68e` | **#181 Phase 1d done:** staged scrollback — libghostty-vt history read via `GHOSTTY_POINT_TAG_HISTORY` + `ghostty_terminal_grid_ref` (untracked refs, safe inside the synchronous sidecar Snapshot command); captured at the same FIFO boundary as `S`, capped `SCROLLBACK_STAGE_MAX_BYTES` = 1 MiB newest-first with truncation logged; new `H` frame (0x48, ≤64 KiB chunks, host→client only) gated on `snapshot`+`scrollback` caps; delivery `attached→S→ready→H…` interleaved with live `D` via a one-chunk-per-loop `yield_now` select arm; H bytes ride the 4 MiB backlog accounting; resize barrier cancels unfinished history (restaging deliberately deferred). Spec C.2/C.6 updated. Verified independently: Mac (8+3 tests, 42 smoke, 8 remote, musl cross) and ukvps native (8 tests, 42 smoke). |
| `faeb16d`…`544c51f` | **#181 Phase 1e done (v1.1 G diffs):** `take_damage()` in the vt crate (global+per-row damage read/clear); `G` frame (0x47, versioned: frame_seq u32 monotonic, cursor, dirty rows × 16-byte wire cells) gated on `grid_diff` (requires `snapshot`, dropped at hello otherwise); single ordered `SidecarResult` channel (Snapshot/Grid/Keyframe — two channels could let a G overtake its S and regress rows); grid clients skip raw-D fan-out entirely (zero backlog reserve), pending clients discard pre-boundary G; keyframes every 256 flushes (env `FYOLOD_KEYFRAME_EVERY` for tests) as S+`ready`; damage encoding is zero-cost with no grid client (`SetGridDiff` interest toggle); sidecar death disconnects grid clients with a typed retryable error; CLI `attach --grid-diff` (raw D stays default). Verified independently: Mac (10+4 tests, 48 smoke, 8 remote, musl cross) and ukvps native (10 tests, 48 smoke). |
| `59b5b7a` | **§C.12 step 1: `fs.list` + `fs.read` (capability `files`).** Batched `fs_list` (2000-entry pages, per-path failure so a speculative batch never sinks whole, `unloaded_dir` stubs for VCS dirs, reply stamped with the `fs:` resource cursor taken *before* the walk); `fs_read` = `fs_file` header + new `F` frame (0x46, 64 KiB chunks, flagged last chunk, 1 MiB soft cap, range). Confinement: canonicalise + reject dotdot/symlink escape from the root. Verified: 30 unit, 62 smoke (Mac). |
| `05a06ef` | **§C.12 step 2: chunked uploads (capability `upload`).** `upload_open` → `U` frames (0x55, ≤64 KiB) → `upload_commit`/`upload_abort`; credit-of-one acks (ack = running total, sent only after the write) bound shared-pipe HOL to one chunk; sha256+size verified at commit, dotfile + atomic rename; dest confinement (project root canonical-parent check, `temp:<name>` + `session` → scratch dir 0600/0700, reaped with the session and swept at daemon start); idempotent re-open on same dest+size+hash, conflicting hash → typed error. New dep `sha2`. Verified: 36 unit, 69 smoke (Mac). |
| `743c097` | **§C.12 step 3: `fs.match` name index.** Paths-only per-workspace index: built BFS at idle priority (yield per dir) when the first `subscribe_resource` starts the watch, fed the debounce loop's own batches (one changed dir = one re-list, vanished dir = prefix prune, `full_rescan` = rebuild), evicted with the watch (dropping the entry drops the index task's sender). `fs_match {root, query, limit}` → `{paths[], coverage}`; no index → honest `coverage 0.0`, never an unrequested walk. Ranking: substring > subsequence, basename > path, shorter wins. Verified: 37 unit, 73 smoke (Mac). |
| `9b4a833` | **§C.13: `git:` resource kind + `git.diff` (capability `git`).** Ring state made generic (`ResourceState<B>`), so git reuses cursor/ring/gap/linger verbatim; a `git:` subscription rides the workspace's `fs:` watch via an internal subscriber (one repo = one OS watch) and runs debounced `git --no-optional-locks status --porcelain=v2 -z` (**no-optional-locks is load-bearing**: plain status refreshes the index, which re-triggers the watcher — a feedback loop). Deltas in Zed's two-axis vocabulary, conflicts first-class; gap subscriber gets the full state at the current cursor (only the host can rescan status). `git_diff {root, path, staged?}` → unified diff, 1 MiB cap. **Gotcha fixed en route: get-or-create must thread one map guard** — `subscribe_git` → `start_git_watch` → `fs_entry` re-locking the registry self-deadlocked the first cut (caught by the smoke suite hanging). Deviation vs spec text (worktree edits trigger too, not just `git_meta`) recorded in the doc changelog. Verified: 41 unit, 80 smoke (Mac). |
| `f1d8871` | **§C.12 step 5 (last): `fs.search` + `cancel`.** Host-run `git grep -n -I --untracked --fixed-strings`, results streamed as `search_results` events (50/batch, text capped 512 B/line), one terminal `fs_searched {matches, limit_hit, canceled}`; generic `cancel {request}` kills by request id, idempotent; a dying connection cancels the same way (the per-connection cancel map drops). **Ordering gotcha fixed en route: connection-addressed events must ride the connection's own `out` queue** — the first cut sent results via the resource channel and the terminal reply directly, so the reply could overtake the results (caught by smoke). §C.12+§C.13 now fully landed: caps `files`/`upload`/`git`, 42 unit, 84 smoke (Mac). Spec deviations recorded in the doc's changelog comment. **Not yet run on ukvps** — next daemon deploy should re-run the suite there (`pkill -x fyolod` first; old image keeps serving). |
| _this branch_ | **Agent integration moves in (capability `agents`), stages 1–2.** The agent manifest schema in Rust (`src/agent/manifest.rs`), reading the *same* 15 bundled files the app reads via `include_str!` plus `~/.fyolo[-dev]/config/agents` — a fixture test parses every manifest in both languages and asserts one golden record, in CI on both sides. `install_agents` installs the JSON-manifest dialect (Claude/Codex/Cursor/Copilot/Grok/Droid/Qwen), the script-directory dialect (Cline) and the skill, and reports the plugin/TOML dialects as `skipped` (stage 3). `src/agent/apple_json.rs` reproduces Foundation's `prettyPrinted|sortedKeys|withoutEscapingSlashes` byte for byte — including the ICU key collation, which is **not** byte order — so migrating a user's `~/.claude/settings.json` off the Swift writer rewrites nothing. **Three SSH-era workarounds deleted rather than ported:** the three `$HOME` escapings (the daemon reads `current_exe()`), the `${XDG_CONFIG_HOME:-…}` shell spelling (one `env::var`), and the double CLI probe (one cached login-shell probe). **Gotcha fixed en route: the login-shell probe must not defer to the inherited `PATH`** — a daemon auto-started from `ssh host fyolod stdio` inherits a minimal one, and the first ukvps run silently installed no skill at all, which is the exact failure the device RFC records. Verified on `ukvps`: from one clean baseline, the SSH arm's output and the daemon's are byte-identical across all 15 stage-2 files (incl. an 18 KB user-owned `settings.json`); the only difference in the raw bytes is the binary token, `"$HOME"/'.local/bin/fyolod'` → the daemon's own absolute path. 26 agent unit tests, 138 total (Mac). |
| _this branch_ | **Stage 6: one report path.** `SetStatus` and `Event::Status` grow `transcript_path`, `conversation_id`, `tool` and `prompt_title` — the four facts only the Mac's own socket carried — and *then* every hook switches to reporting through the daemon that owns its PTY. Order matters: switching first would have been a downgrade (no transcript in the Info pane, no `/new` rotation, no tool). `HookReporter` collapses to a `ThisMac`/`Device` marker that only picks the skill payload; the `guard reporter == .fyoloCLI` branch, the three spellings of a binary path, and **every machine branch in `plugin.rs`** are gone — one template per dialect, asserted by `one_template_serves_both_machines`. The app's `agent-status.sock` and `StatusReport` are deleted; `applyFyolodStatus` absorbed what `applyStatusReport` did. `fyolo agent report` keeps its name, states and flags and forwards to `fyolod set-status`, which now takes the same flags and mines the same stdin blob (serde_json, not the shell's hand-rolled scanner). **Two bugs found on the way**, both only possible because there were two paths: hooks emit the manifest vocabulary (`attention`) while the protocol speaks `needs_you`, so a device agent stopped at a permission prompt reported a state no client recognised — the daemon normalizes now; and the local path's `effectiveAgent != .terminal` guard, which existed to make cwd-guessed reports safe, discards every *remote* report (an existing test caught it) and is gone with the guessing. **Ordering**: `Event::Status` is queued into the session's own per-client channel, the same FIFO as its `D` data, so it cannot overtake output the daemon has read and arrival order is correct — `SetStatus.seq` is a request id, not an ordering token. **Gate, both halves**: a hook-shaped `set-status` with a Claude payload round-trips all four fields into `E status` locally *and* on `ukvps`, where none of them could be carried before. 784 Swift tests, 161 Rust. |
| _this branch_ | **Stage 4: Swift calls the daemon.** `AgentConfigStore.swift` deleted whole; the installer halves of `HookListener.swift` and `SessionControl.swift` removed; `InstallOutcome` is now built from the reply. Only the installer half left — the status socket, `StatusReport` and `AgentPromptTitle` stay, and two symbols moved to their real homes rather than dying with the file: `HookDialect` is schema (`AgentDefinition.swift`) and `XDGBaseDirectories` has one consumer left, session-record reading (`AgentSessionStore.swift`). New `install_agents` shape: the two Integration switches are independent, so each half is `install` / `remove` / `leave` rather than one `enabled` flag — that is what keeps one message *one* message when the switches disagree. New `probe_agents`, because deleting `SSHAgentConfigStore` would otherwise have left the readiness rung doing one `ssh` per agent. **Gate, measured on `ukvps` by counting `ssh` invocations** (a wrapper on `PATH`, plus an instrumented throwaway checkout of main for the before): install of 12 agents **98 → 1**; the agent probe **45 → 1**. **Local install is now IPC**: `Transport.open` already auto-starts `fyolod serve`, so a daemon that is not running is recovered from, not reported; what cannot be recovered is logged and surfaced, never swallowed. **Skew**: the install refuses by *capability*, not by version, and the device pane's foundation rung redeploys a daemon that lacks `agents`. Verified live against ukvps's genuinely old daemon — a named refusal, not a no-op. A running old daemon is **not** restarted: `mv` leaves it holding the old inode, and a fyolod restart kills every session it owns (ukvps had 15). That state is named with its cost instead. **D4's precondition stays**, in its cheap local form: `expect_sha256` was for a *remote* check-and-swap and goes with the link; the user's editor is still on this machine and `~/.claude/settings.json` is a file people keep open. 651 Swift tests, 157 Rust. |
| _this branch_ | **Stage 3.5: per-agent config-home overrides.** Every manifest hardcoded `~/.claude`, `~/.codex` and friends, and fyolo honoured no override — so a user who moved their config got an install into a directory the agent never reads, silently, because every hook form ends in `2>/dev/null || true`. Same class as the XDG miss and more common, since people set these for profile isolation. New optional `configHome: {env, path}` in the schema, parsed in both languages and in the golden record; `machine::resolve` honours it in the daemon, falling back to the manifest path when the variable is unset or empty. **The prefix is stated, not derived** — Pi's variable would name `~/.pi/agent`, not `~/.pi`. Manifests are validated: every hook/skill path must sit under the declared prefix, matched by path component so `~/.pi/agent` never claims `~/.pi/agentic`. Filled in for the six agents whose own docs document one: `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `GROK_HOME`, `COPILOT_HOME`, `KIMI_CODE_HOME`, `HERMES_HOME`. **Left absent for nine, each checked and recorded in the PR** — notably `OPENCODE_CONFIG_DIR`, which its docs describe as an *additional* directory searched alongside `~/.config/opencode`, not a relocation; `CURSOR_CONFIG_DIR` (moves `cli-config.json` only); `CLINE_DATA_DIR` (moves `~/.cline/data`, while hooks and skills stay above it); and `PI_CODING_AGENT_DIR`, which exists but is not in Pi's own docs. **A comma-separated `CLAUDE_CONFIG_DIR` is refused, not guessed**: Claude Code's own entry describes a single directory and the comma form is ccusage's convention for *reading* across profiles; installing into the first would wire one profile and leave the others silent. Ordering decided rather than left to chance: an agent's own variable outranks the XDG base, which applies only when the agent variable is unset. Verified on `ukvps`: unset installs to the default, `CLAUDE_CONFIG_DIR=~/claude-profile` moves both the hook file and the skill, a comma value fails visibly and writes nothing, and the stage-2/3 byte-identical gate is unchanged at 19/19. 42 agent unit tests. |
| _this branch_ | **Stage 3: the plugin dialects and the TOML block.** All six dialects now install from the daemon. `src/agent/plugin.rs` generates the OpenCode, Pi and Amp sources — the one dialect whose hook is *source* rather than a command string, which is why the device traps live there: Bun's `$` escapes each interpolation into one argv token (so a `$HOME/…` path reaches the kernel as a literal `$HOME`), a plugin loaded outside a fyolod session must report nothing rather than call `set-status` with an empty id, and a device drops the conversation plumbing because `SetStatus` carries state and title only. All three fail silently — every form ends in `.quiet().nothrow()` or `2>/dev/null || true`. Pi keeps no device branch: it already shells out through `pi.exec("sh", …)`, so it takes the shared command string. `report_command` now takes an explicit `StdinMining` rather than reading the spec, because only the JSON dialect may mine stdin — Swift passes the bare form to the other four and reading `capturesTranscript` off a scripts/TOML manifest would have emitted a flag that hangs the hook. **Gate, on `ukvps`, run twice:** from one clean baseline, the SSH arm and the daemon produce byte-identical output across all **19** files for the device reporter (one normalization: the binary spelling), and across all 19 **with no normalization at all** for the Mac reporter — the second arm pairs the SSH *store* with the local reporter, which is the only way to compare the Mac's plugin templates without writing into a developer's own home. It caught a stray blank line in the OpenCode Mac template that a hand-written unit test had agreed with. Reinstall verified on the box: three installs with changing stamps leave exactly one plugin file, one TOML banner and three hook tables. Measured while there: the SSH arm duplicates **JSON** hooks on reinstall (12 entries where 6 belong) but *not* plugin or TOML, whose markers are dialect-owned rather than reporter-dependent. 38 agent unit tests, 153 total (Mac). |

All of #180 and #179 were **deployed to the VPS `ukvps` and tested live**:
no throughput regression (16–24×), the backlog drop fires ("dropping slow client
… exceeded 4 MiB") with RSS bounded, observe-over-SSH delivers full output.

---

## 3. Key decisions and their rationale (do not re-litigate)

- **VT engine = libghostty-vt, NOT alacritty_terminal.** The spike recommended
  alacritty (builds without Zig), but the user overrode it on a **correctness**
  ground: every fyolo client *is* libghostty (Mac embeds it, iOS mirrors it), so
  the host authority must run the **same** VT or the synchronized-state-machine
  model breaks (grapheme/width/autowrap/escape divergence → the host's snapshot
  wouldn't match what a client renders). Fidelity parity is worth the Zig/FFI
  cost. Proven: the FFI snapshot resolves the green cell to Ghostty's real
  `rgb(181,189,104)`, identical on Mac and Linux.
- **Wire cell is engine-independent.** libghostty-vt cells are opaque; there is a
  conversion step. Keep it behind a neutral boundary so the engine stays swappable.
- **Develop the Linux daemon natively on Linux (the user's steer).** Cross-from-Mac
  was a POC shortcut; for the run/debug/integrate loop, build on the target.
  libghostty-vt builds natively on `ukvps` in ~3 min (Zig is a cross-compiler, so
  cross also works, but native is the dev workflow going forward). Note fyolod
  *also* builds for macOS-arm64 (it's the local host too — "local = remote to
  localhost"), so **both targets must keep working**.

---

## 4. Environment and artifacts

**Worktree layout** (under the worktree root):
- `fyolod/` — the daemon+client crate (`src/{daemon,session,client,protocol,pty,remote,main,paths}.rs`).
  - `smoke_test.py` (27 checks), `remote_smoke_test.py` (8 checks) — keep green.
  - `bench/bench_100x.py` (+ `README.md`) — the anti-100× benchmark.
  - `vt/` — fyolod's snapshot boundary. The engine comes from the
    `libghostty-vt` crate, which owns the Zig build and the FFI; this crate owns
    only the engine-neutral wire cell. Nothing is vendored.
  - `spike/` is gone: both proofs (alacritty `vt-sidecar`, libghostty-vt
    `vt-ffi`) were standalone and are preserved in history at `bc36438`.
- `docs/design/20260730-fyolod-session-protocol.md` — **the spec** (§A invariant, §C.5/§C.6
  terminal plane, §D transports/QUIC, §E matrix, §F risks — incl. #9 pipe-mode,
  #10 backlog, #11 resize, and the general v1 plan). Read this first.
- `docs/design/20260730-fyolod-session-mux.md`, `20260731-fyolod-vt-sidecar-spike.md`.

**Toolchains:**
- Mac Zig **0.16.0**: `~/.local/share/fyolod-toolchains/zig-0.16.0/zig`. It must be on
  `PATH` — `libghostty-vt-sys` invokes `zig` by name and honours no `ZIG` override.
  Build with `PATH=<that dir>:$PATH DEVELOPER_DIR=/Library/Developer/CommandLineTools
  cargo …` (the `DEVELOPER_DIR` avoids Xcode 26.4's arm64e-only SDK). `libclang` is
  no longer needed on the host: the `-sys` crate ships pre-generated bindings.
- The VPS needs no Zig and no Rust: `remote deploy` cross-compiles the static musl
  binary on the Mac and ships the ELF. A native build on the box needs the 0.16
  toolchain there; `ukvps` now has it at the same path as the Mac. It still cannot
  complete one: Zig's own TLS client fails to reach `deps.files.ghostty.org` from
  that host (`TlsInitializationFailed`) while `ziglang.org` and `github.com` fetch
  fine, so ghostty's package fetch dies. `GHOSTTY_ZIG_SYSTEM_DIR` (a pre-seeded
  package store) is the way around it if a native build is ever needed there.
- The old vendored `build.rs` pinned Zig to 0.15.2 and rejected `linux-gnu`. That
  is gone with the vendored tree: the fork's `-sys` crate builds for the host it
  is given. `.github/workflows/fyolod.yml` leans on that — one job builds, tests,
  smokes and cross-compiles on macOS, a second does the same natively on
  `ubuntu-24.04-arm`, both from this checkout.

**Deploy path:** `fyolod remote deploy ukvps` cross-compiles the daemon
(aarch64-musl) from the Mac and scps it. Stop the running daemon first (`ssh ukvps
pkill -x fyolod`) or scp fails with `ETXTBSY`. SSH host alias `ukvps`
(130.162.188.52, user ubuntu) is in `~/.ssh/config`.

**Live sessions at handoff** (see §5 for how to use them):
- `terminal@f01bf339` — a persistent **SSH shell into ukvps** (the Linux dev session).
- `codex@48692b12` — **warm, unblocked, full context** (did #180, #179, the reviews,
  the VT spikes). **Reuse this one** for continuity.
- `codex@651402ce` — did the SIMD + Mitchell-talk reviews.

---

## 5. How to orchestrate the sibling agents (read carefully — real gotchas)

You drive siblings with the `fyolo sessions` CLI (scoped to this project;
`--json` for machine output). Core verbs: `list`, `spawn "<prompt>" --agent codex`,
`send <handle> "<text>"`, `read <handle>`, `run "<cmd>"`, `watch`, `focus`, `close`.

**Discipline that worked and you should keep:**
1. **Prefer reusing `codex@48692b12`** (warm + full context) over spawning fresh —
   see the hook-gate gotcha below.
2. **Dispatch with `send --wait --timeout <ms>`.** Long tasks usually **time out**
   the wait (reply: "still working after the wait") — that's fine; then **poll**
   `fyolo sessions list --json` until the session's status ≠ `working`, and read
   the result. A background poll loop works well.
3. **Read the reply from the Codex transcript, not the screen.** The screen
   (`read`) only shows the tail. Get the latest file at
   `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` and extract the last `assistant`
   message (the Python one-liner used throughout: iterate lines, JSON-parse,
   collect `payload.role=="assistant"` text, print the last).
4. **ALWAYS independently verify Codex's claims** before trusting/reporting —
   rebuild the crate, re-run the proof/smoke tests yourself, review the diff.
   Every Codex deliverable this session was independently re-run (and one build
   caveat — `ZIG`/`DEVELOPER_DIR` env — was caught this way).

**CRITICAL GOTCHA — the Codex hook-trust gate.** A freshly `spawn`ed Codex boots
into a "⚠ N hooks need review / Press t to trust all" gate (fyolo's own
`agent report` hook, "modified since last trusted"). **You cannot clear it with
`fyolo sessions send "t"`** — `send` appends a Return, so `t\n` = trust-all
*then* the Return triggers "enter to review hooks", reopening the gate. It needs a
**bare keypress**. Workarounds: (a) **reuse an already-unblocked Codex** (best), or
(b) `fyolo sessions focus <handle>` and ask the **human to press `t` once** in the
pane, then re-send your task (the spawn's queued prompt is usually lost in the
churn — resend it). This bit us twice; budget for it.

---

## 6. Next steps — Phase 1 (issue #181)

**ALL of Phase 1 is DONE (2026-07-31, single day, phases 1a–1e — see the §2
table for commits and verification).** The #181 protocol ladder shipped whole:
`S` snapshot-on-attach + `ready` (1a) · resize-as-barrier + TIOCSWINSZ
surfacing + writer-failover size reclaim (1b) · authoritative `rows`/`cols` in
`attached` (1c) · staged scrollback `H` frames (1d) · capability-gated `G`
dirty-row diffs with keyframes, the v1.1 plane (1e). Suites: 48 local + 8
remote smoke, 10+4 unit; everything dual-verified on macOS-arm64 and native
aarch64-musl (`ukvps`). Hands-on Mac→Linux test steps: `DEPLOY.md`.

### Remaining directions (each needs a human product call before dispatch)

1. **`fyolod stdio` bridge — DONE (`cbe9e23`, 2026-08-01).** `fyolod stdio`
   is a transparent byte relay splicing stdin/stdout to the local daemon socket
   (no frame parsing of its own); run as `ssh <host> fyolod stdio` it puts the
   framed protocol itself on the SSH pipe. Deterministic Rust integration test
   (`tests/stdio_bridge.rs`) drives hello → attached → S → ready → live D
   through the bridge and asserts byte-identical ordering — the §C.9 claim is
   now real. The daemon auto-starts like every other verb. **Next, to make
   remote work IN THE APP** (the differentiated demo — agent runs on a Linux
   box, you attach from the Mac): **DONE (`b91d180`, 2026-08-01).**
   `FyolodSessionLink` now has a transport seam (`Fyolod.Transport`): local
   Unix socket, or an SSH pipe to `ssh <host> fyolod stdio`. Set
   `FYOLO_FYOLOD_REMOTE=<host>` with the flag on → new sessions run on that
   Linux host, the Mac attaches over SSH; the whole M2/M3 client (attach,
   snapshot repaint, detach-not-kill) reused unchanged, only the pipe differs.
   Verified end-to-end against the real `ukvps` VPS: the Swift SSH transport
   does hello → attached → S snapshot (24×80, decoded) → ready through
   `ssh ukvps fyolod stdio`. System OpenSSH is the trust plane; fyolo never
   ships an SSH server (§H #8). **Remaining for the app remote demo:** a real
   UI to pick the host per session (today it's one env-configured host); remote
   sessions currently spawn a plain login shell (agent-on-remote — e.g. `claude`
   on the VPS — needs argv/env wired for the remote, and the agent installed
   there); the live GUI recording.
   **UI landed (`55b2734` + `8e86866`, 2026-08-01):** per-project `+` ▸
   **New Remote Terminal** submenu from `SSHConfig.hosts()` (~/.ssh/config, the
   single host source), opening a `.terminal` session on the picked host;
   per-session `Session.fyolodRemoteHost`/`fyolodRemoteCwd` (persisted,
   `decodeIfPresent` back-compat) replace the global env as the source of truth
   (env stays a fallback). `ensureRemoteReady` deploys fyolod if missing +
   reachability-gates before attach, with a HUD and typed failure alerts.
   Project right-click **Clone on Remote…** → pick host → `ssh <host> 'cd ~ &&
   git clone <origin> <name>'` (origin/unpushed-count via new
   `GitService.cloneInfo`; unpushed-commits warning; `BatchMode=yes`; captures
   the clone's absolute path via `printf $PWD/<name>` since the daemon chdir is
   raw) → opens a remote terminal in the cloned dir. Flag-off/local paths stay
   byte-identical (all gated behind `Fyolod.isEnabled`). Verified: `swift
   build` clean; the deploy probe, clone command shape, and daemon absolute-cwd
   all confirmed against real `ukvps`. NOT yet verified (needs live GUI with
   `FYOLO_FYOLOD=1`): the menu clicks, HUD/alert rendering, in-app attach over
   `fyolod stdio`, live snapshot repaint.
   Verification caveat worth keeping: driving the bridge from a Python
   `subprocess` pipe is flaky at startup (a harness-side stdin/stdout timing
   race, NOT a bridge bug — direct-socket and bridge both pass 6/6 on hello,
   daemon logs clean); use the Rust integration test, not a Python pipe.
2. **Mac app integration (#170) — IN PROGRESS (M2+M3 landed 2026-08-01,
   `29de132` + `508ace2`).** fyolo.app is now an opt-in attach client of the
   local daemon (`FYOLO_FYOLOD=1`), the demo's whole point — quit the app,
   the agent keeps running; relaunch, it reattaches with a clean repaint.
   - **M2** (`29de132`): sessions run inside the daemon (attach with
     `create_if_missing`, named by the app session UUID so relaunch rejoins by
     name — same pid); output enters the surface at the same
     `InMemoryTerminalSession.receive` seam the in-process PTY feeds; quit →
     `detach()`, never kill; flag-off path is byte-identical to today. All new
     code in `Sources/fyolo/Terminal/Fyolod/` (`FyolodClient.swift`,
     `FyoloStore+Fyolod.swift`).
   - **M3** (`508ace2`): attach offers the `snapshot` cap; the `S` frame is
     decoded (`FyolodSnapshot.swift`) and synthesised into a truecolor ANSI
     repaint through the same seam, before live `D` (single serial reader
     preserves order, no hold-back). Replaces M2's ring-replay tear with a
     clean frame; the resize-barrier keyframe repaints idempotently.
     Colors arrive resolved; `attributes` is reserved-zero so bold/underline
     aren't carried yet.
   - **Verified:** `swift build` green; decode+render unit-checked against both
     a hand-built payload and a **real captured daemon S frame** (content +
     ordering). **NOT yet verified live in the GUI** — the prod app wedged on
     the SwiftUI main thread during M2 testing (see [[fyolo-split-flicker]]);
     the ⌘Q→relaunch demo needs a running app to record.
   - **Remaining for #170:** launchd user-agent plist (so the daemon is up
     before the app and survives reboots) · `Close Session` verb wired to
     `kill` (destroy path) · self-update relaunch story · the live GUI demo
     recording. The `--grid-diff`/scrollback planes stay out of the app until a
     deeper libghostty integration (a byte-stream surface can't inject history
     above the viewport nor consume dirty-row diffs).
3. **QUIC binding (§D.1)** — stays gated on measurement by design. With the
   `G` plane now real, re-measure the three motivating numbers (p95 echo under
   loss, cold-exec latency, roaming) before spending anything here.
4. **Land the branch** — PR #177 is functionally complete and dual-verified;
   promoting it from draft / merging to main is a release-timing call.
5. **Small follow-ups (no product call needed, bundle opportunistically):**
   portable `.cargo/config.toml` (Mac-absolute `ld.lld` path breaks native
   Linux builds — delete/exclude it there; see gotcha in §2 table) ·
   resize-time scrollback restaging (deliberately deferred in 1d) · H/G
   delivery pacing beyond the 4 MiB backlog rule · keyframe cadence tuning
   (256 is a guess).

---

## 7. Open questions for the human (get answers before big dispatches)

1. **Phase 1 scope:** the small 1a slice (snapshot-on-attach + `ready`) first, or a
   larger v1 chunk in one go? (Recommend 1a — smallest end-to-end proof.)
2. **Dev location:** develop Phase 1 **natively on ukvps** (needs the full `fyolod`
   crate rsynced there — the user leaned this way), or code on Mac + run/test on
   ukvps? Either way both targets must keep building.
3. **When to open a real (non-draft) PR / merge to main** — the branch has grown
   large; consider whether to land the shipped pieces (#179/#180 + bench + docs)
   before the bigger v1 work.

---

## 8. Pointers

- Issues: #164 (epic), #179 ✅, #180 ✅, #181 (active). Design: the three
  `docs/design/YYYYMMDD-fyolod-*.md` files. Bench: `fyolod/bench/`.
- Prior art on disk: herdr vendors libghostty-vt at
  `/private/tmp/herdr-inspect/vendor/libghostty-vt/` (build.zig + CMakeLists +
  `include/ghostty/vt.h`); local ghostty checkout at `~/Documents/GitHub/ghostty`.
- The real VT API is `include/ghostty/vt.h` (NOT the app-level `ghostty.h`):
  `ghostty_terminal_new`, `ghostty_terminal_vt_write`, cursor/dims, render-state
  cell iteration, per-row dirty tracking — enough for `S` and `G`.
- User working style (honor it): keep fyolod minimal and focused; name mechanisms
  not agents; verify before claiming done; report failures honestly with output;
  don't re-pitch dropped ideas.
