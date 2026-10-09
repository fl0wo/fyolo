# fyolod — durable session host

> **A session lives in a host. Viewers only attach.**  
> **Composable** · **Direct.** Local is remote to localhost. Detach ≠ kill.

`fyolod` is fyolo’s **session host**. Composable parts (host · protocol · clients · pipes). Direct path (client → host → PTY). The CLI is a **reference client**, not the architecture.

Full model: [`ARCHITECTURE.md`](ARCHITECTURE.md) · design: `docs/design/20260730-fyolod-session-mux.md` · epic [#164](https://github.com/jiweiyuan/fyolo/issues/164) · POC [#170](https://github.com/jiweiyuan/fyolo/issues/170)–[#172](https://github.com/jiweiyuan/fyolo/issues/172) · draft PR [#177](https://github.com/jiweiyuan/fyolo/pull/177).

```
  clients (Mac / iOS / CLI)          host (fyolod)
         │                                │
         │   Session Protocol             │ owns PTYs
         ├──── Unix socket (local) ──────►│
         └──── SSH pipe (remote) ────────►│──► shell / agent
```

## Build

```sh
cd fyolod
cargo build            # ./target/debug/fyolod
cargo build --release
```

One binary = **host** (`serve`) + **clients** (`attach`, `list`, …) + **SSH transport helpers** (`remote …`).

## Host (local)

```sh
fyolod serve          # foreground host (usually auto-started)
```

Socket: `$XDG_RUNTIME_DIR/fyolod/fyolod.sock`, else `/tmp/fyolod-<uid>/fyolod.sock`  
(`0700` dir, `0600` socket). Override: `FYOLOD_SOCK`.

For clients that cannot open a Unix socket — a phone, a browser — `serve` takes
an opt-in **loopback** WebSocket carrying the same framed protocol. Off by
default; off-loopback binds are refused at flag parse, and TLS belongs to
Tailscale Serve or Caddy in front. See [DEPLOY.md](DEPLOY.md).

```sh
fyolod pair                                       # mint and print the token
fyolod serve --wss 127.0.0.1:8790 --wss-origin https://box.tailnet.ts.net
```

## Clients (local)

```sh
fyolod attach demo                    # create-on-missing; Ctrl-\ detaches
fyolod attach build -- npm run dev
fyolod list
fyolod list --json
fyolod create --name api --cwd ~/proj -- bash
fyolod send api "npm test"            # inject without attach
fyolod set-status api needs_you --title "Review requested"
fyolod kill api
```

Multi-client: several `attach` to the same session — output fans out. There
is one writer: the newest `mode:"interact"` claim wins, while
`mode:"observe"` never claims it. A demoted writer remains attached.
Non-writer input/resize receives a typed `not_writer` error; writer changes
and accepted resizes are event frames.

## Session Protocol v0.1

Framed stream: `[kind:u8][len:u32 BE][payload]`

| kind | payload | meaning |
| --- | --- | --- |
| `C` | `op`-tagged JSON | control and correlated responses |
| `D` | raw bytes | PTY I/O (hot path) |
| `R` | `rows:u16, cols:u16` | resize (TIOCSWINSZ) |
| `E` | `ev`-tagged JSON | status, writer, resize, exit, and roster events |

Frames are capped at 16 MiB; writers split `D` into chunks of at most 64 KiB.
Unknown control operations/events are ignored, while an unknown frame kind is
a typed `proto_error` followed by channel close.

Every v0.1 channel begins with `hello` and declares `role:"control"` or
`role:"attach"`, a protocol range, and capabilities. The host negotiates
protocol 1 and the capability intersection (`events`, `send_wait`), returning
its stable `host_id` and a connection-scoped `client_id`. An incompatible
range gets `hello_err` and an immediate close. A first v0 control operation
without `hello` is accepted as a legacy connection with no capabilities, so
old clients continue to work.

Requests may carry `seq`; responses echo it as `re`. Control channels can
`subscribe` to roster/status events, `wait` for session state, and call
`set_status` for workstream metadata. `create` accepts optional
`workstream {agent_id, project, worktree}`; `list` exposes status/title,
attachment count, and writer identity.

Later: host-side vt snapshot / diffs (not in this POC). No panes inside the
host (zmx lesson).

## Remote (SSH is a pipe)

Transport is **system OpenSSH** only — no public listener. The **host still runs on the VPS**; SSH only reaches it.

```sh
fyolod deploy --host my-vps           # install or update ~/.local/bin/fyolod, verify it
fyolod remote list my-vps
fyolod remote attach my-vps demo -- bash
fyolod remote open my-vps --cwd '~/proj' --agent shell
```

`deploy` is one loop for every state a box can be in — nothing installed, an
older binary, a newer binary the daemon has not picked up. It stages the build
this binary carries, asks the running daemon to take it on, checks the new one
answers, and puts the previous binary back if it does not. Running it again is
the recovery from any outcome.

Taking it on is an **`execve`**, not a restart: the daemon replaces its own
image while keeping its pid, its children and every PTY master, so upgrading a
box does not cost the work running on it. On the box itself, `fyolod handoff`
is that verb by hand, `fyolod status` says what is there, and `fyolod stop`
asks the daemon to leave — declined, with the sessions named, while a command is
running or an agent is mid-task. Stopping is now only the fallback for a daemon
too old to replace itself.

`my-vps` = `~/.ssh/config` alias. Close the laptop; reattach — agent kept running on the VPS. See [`DEPLOY.md`](DEPLOY.md).

## Test

```sh
cargo build
python3 smoke_test.py          # 27 local checks (16 v0 + 11 v0.1)
python3 remote_smoke_test.py   # #171/#172 — 8 checks via fake-ssh
```

## Layout

| path | part |
| --- | --- |
| `src/daemon.rs` · `session.rs` · `pty.rs` | **Host** |
| `src/protocol.rs` | **Protocol** |
| `src/client.rs` · `main.rs` | **Reference client** |
| `src/remote.rs` | **SSH transport** helpers |
| `ARCHITECTURE.md` | Clean model |
