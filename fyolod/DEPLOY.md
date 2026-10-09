# Deploying fyolod to a Linux VPS (over SSH)

fyolod runs remotely with **no custom network stack**: the transport is your
own OpenSSH, and SSH is also the access-control boundary. The remote daemon
listens on a **Unix socket only** — never `0.0.0.0`. This covers issues
**#171** (deploy + remote attach) and **#172** (`remote open`).

Clients that cannot speak SSH — a phone, a browser — reach the box through an
opt-in **loopback** WebSocket instead, described under
["Serving a phone or a browser"](#serving-a-phone-or-a-browser-opt-in). It is
off unless you turn it on, and it never binds a public address.

## Hands-on: test the remote terminal from a Mac, step by step

Everything below assumes an SSH alias in `~/.ssh/config` (the examples use
`ukvps`) and the toolchain from "Cross-compiling on the Mac" below.

```sh
# 1. Build the CLI on the Mac (from the repo's fyolod/ directory)
export PATH=$HOME/.local/share/fyolod-toolchains/zig-0.16.0:$PATH
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
cargo build
alias tio=./target/debug/fyolod

# 2. Deploy to the VPS. The running daemon keeps executing the old image until
#    it is told otherwise, so deploy stages the new binary beside it and then
#    asks it to hand off — same pid, same PTYs, sessions intact.
tio remote deploy ukvps

# 3. Open a durable session and attach (creates + attaches in one command;
#    --agent claude/codex launches an agent instead of a shell)
tio remote open ukvps --name demo

# 4. Inside the session: start something long-lived, e.g. `top`.
#    Detach with Ctrl-\  (the session KEEPS RUNNING on the VPS).
#    Simulate a real drop instead: close the laptop lid or kill Wi-Fi —
#    a dead SSH connection is also just a detach, never a kill.

# 5. Proof of survival — same pid before and after:
tio remote list ukvps

# 6. Reattach. v1 bootstrap kicks in: one S snapshot repaints the CURRENT
#    screen (top, mid-run, no replayed escape torrent), `ready`, then live
#    bytes; scrollback is staged behind it (the CLI prints
#    "scrollback: N rows staged" when you detach).
tio remote attach ukvps demo

# 7. Second read-only viewer (scripting/piping — no tty, no input):
tio remote attach ukvps demo --observe | head -50

# 8. Done? End the session for real:
ssh ukvps '~/.local/bin/fyolod kill demo'
```

What you are testing at each step: durable host (4–5), snapshot-on-attach
(6, Phase 1a), staged scrollback (6, Phase 1d), single-writer + observer
plane (7, #179). The resize barrier (1b) fires whenever you resize your
terminal while attached as the writer — observers repaint from a fresh
snapshot instead of parsing at the wrong width. The `grid_diff` plane (1e)
has no remote CLI flag yet (`attach --grid-diff` is local-only today); it
rides the same framed protocol, so it lights up remotely once `fyolod stdio`
lands (see the protocol doc's roadmap).

## The one-liner

```sh
fyolo remote open my-vps             # deploy if needed, create a session, attach
```

`fyolo remote …` is the spelling on a machine that has the client — the
script execs the daemon bundled beside it, so it always matches the app's
channel. On the box itself there is only `fyolod`, which is why the SSH
examples below keep that name. `my-vps` is any `~/.ssh/config` alias (or
`user@host`). Behind that:

1. `ssh my-vps test -x ~/.local/bin/fyolod` — installed? If not, deploy.
2. `ssh my-vps fyolod create …` — create a durable session; capture its id.
3. `ssh -t my-vps fyolod attach <id>` — attach over an SSH PTY.

Close your laptop mid-session; the daemon on the VPS owns the PTY, so the agent
keeps running. Reconnect with `fyolo remote attach my-vps <id>` (or `open`).

## Cross-compiling on the Mac

Since v1 the crate embeds **libghostty-vt** (the `fyolod/vt` crate), which is
built by **Zig 0.16.0** via `build.rs` — Zig doubles as the C cross-compiler,
so the output is still a single **static musl** Linux binary and no
`musl-gcc`/Docker is needed. Rust-side cross-linking uses the `rust-lld` that
ships with the toolchain, wired in `.cargo/config.toml` (checked in; it names
`rust-lld` rather than a path, so it resolves from whatever toolchain is active
and is fine to keep when building natively on Linux). Required environment on
the Mac:

```sh
# On PATH, under that exact name: `libghostty-vt-sys` invokes `zig` by name and
# honours no `ZIG` override.
export PATH=$HOME/.local/share/fyolod-toolchains/zig-0.16.0:$PATH
export DEVELOPER_DIR=/Library/Developer/CommandLineTools   # avoids Xcode 26's arm64e-only SDK
```

One-time target install:

```sh
rustup target add aarch64-unknown-linux-musl   # ARM VPS (Graviton, Ampere, Pi)
rustup target add x86_64-unknown-linux-musl     # Intel/AMD VPS
```

`fyolo remote deploy <host>` runs `uname -sm` on the host, picks the matching
target — the slice bundled beside the binary when there is one, a cross-compile
otherwise — and installs. On a Linux box the `fyolo` client installs beside the
daemon in the same pass, so a box's client and daemon are always the same build.
A Mac is sent no client: its own app bundle links one into `/usr/local/bin` and
keeps it current, and a second copy in `~/.local/bin` would only shadow it.
Manual build:

```sh
cargo build --release --target x86_64-unknown-linux-musl
file target/x86_64-unknown-linux-musl/release/fyolod
# → ELF 64-bit, statically linked  (runs on any glibc/musl Linux of that arch)
```

If you'd rather use a real musl cross-toolchain (e.g. for C deps later),
install one and override `linker` in `.cargo/config.toml`, or build on the host
and deploy the prebuilt binary:

```sh
fyolo remote deploy my-vps --bin path/to/linux/fyolod
```

## What deploy does

One reconcile loop (`src/lifecycle.rs`; the design is
`docs/design/20260827-fyolod-lifecycle-reconcile.md`):

```sh
fyolo remote deploy my-vps
#  ssh  my-vps ~/.local/bin/fyolod status --json   # observe: binary, daemon, sessions
#  scp  <bundled slice>  my-vps:.local/bin/fyolod.new
#  ssh  my-vps 'chmod +x … && mv fyolod fyolod.prev && mv fyolod.new fyolod'   # stage
#  ssh  my-vps ~/.local/bin/fyolod handoff --json  # activate — execve in place, sessions kept
#  ssh  my-vps ~/.local/bin/fyolod stop --json      # only if the daemon is too old to hand off
#  ssh  my-vps ~/.local/bin/fyolod stdio            # verify: hello, compare the version
#  on failure: mv fyolod.prev fyolod                # roll back
```

Each step is skipped when the observed state already matches: a box on the
current build costs one `status`.

Activation is a **handoff**: the running daemon `execve`s the staged binary,
keeping its pid, its children and every PTY master, so the sessions on the box
do not notice the upgrade and work in progress is never a reason to postpone
one. Clients are disconnected — their sockets die with the image — and reattach
by session id to find the session alive.

Stopping is the fallback, for a daemon too old to know the verb. There a box
whose daemon has work in progress — a command running in a session's
foreground, or an agent still `working` — is left **staged**: the new binary is
in place and takes over the next time the daemon is stopped, and the sessions
are named so the decision is the user's. A client attached to an idle prompt
does not hold it up. `--force` overrides.
The version compared is the app's build stamp (`0.44.0+1533`), carried by the
daemon at `hello`; a box a newer app set up is left alone.

Install path is `~/.local/bin/fyolod`, with the `fyolo` client beside it on a
Linux box. Override with `FYOLOD_REMOTE_BIN` (e.g. `/usr/local/bin/fyolod`) on
the client for both deploy and attach; the client's path moves with it, unless
the override also renames the daemon, which deploys the daemon alone rather than
renaming the box's own client aside. Verification covers both: the daemon must
answer `hello` as the new build, and an installed client must answer `--version`
with at least that stamp. A client that fails leaves the machine running and
reported as current with the trouble named — nothing on the box is stopped for
it, and the next deploy installs the client again.

Sessions find the client without any dotfile write: fyolod keeps a directory
holding one symlink to the paired `fyolo` and leads every session's `PATH`
with it. A directory of its own rather than the daemon's — leading with, say,
`/usr/local/bin` would put every binary in it ahead of the user's own `PATH`.

A session started with a command (every agent) re-asserts that entry on the
login shell's own command line, after its startup files have run. A plain
terminal has no such line, so on a box whose `/etc/profile` reassigns `PATH`
outright — Debian and Ubuntu do — a plain terminal resolves `fyolo` only if
the install directory is on the `PATH` that profile builds. `~/.local/bin` is,
for the shells that read `~/.profile`. So put the install directory on the
remote `PATH` if you want to type `fyolo` in a plain terminal there; the
`remote` subcommands and the agent hooks always have it.

## Starting the daemon: on-demand (default)

No service required. The daemon **auto-starts, detached (`setsid`), on the
first client op** (`attach`/`list`/`create`). Because it's in its own session,
it survives the SSH channel closing — that's the whole durability trick.

### Optional: a user systemd unit

If you want the daemon always up (so `list` is instant, sessions predate any
attach, and a crash or a reboot brings it back), let it install its own
`--user` unit:

```sh
ssh my-vps ~/.local/bin/fyolod service install
ssh my-vps ~/.local/bin/fyolod service status
```

`service install` writes the unit below to `~/.config/systemd/user/`, runs
`systemctl --user enable --now` on it, and tries `loginctl enable-linger` for
you. Linger is what keeps the daemon alive **after you log out**: without it
systemd stops the user's manager — and every unit in it — when the last
session closes, so sessions would vanish silently between SSH connections.
Enabling linger over SSH is sometimes refused by polkit; when that happens the
install still succeeds and prints the one command left to run:

```sh
ssh my-vps loginctl enable-linger $USER
```

The unit is generated from the absolute path of the binary that installed it,
so it never depends on `PATH`:

```ini
# ~/.config/systemd/user/fyolod.service — what `fyolod service install` writes
[Unit]
Description=fyolod session host

[Service]
ExecStart="/home/you/.local/bin/fyolod" serve
Restart=on-failure

[Install]
WantedBy=default.target
```

`Restart=on-failure` rather than `always`: `fyolod stop` (and `deploy`) sends
`SIGTERM` and waits for the socket to stay gone, and the next client contact
starts the unit again — a client never forks a second daemon beside a unit
systemd owns. A dev build (`FYOLO_CHANNEL=dev`) installs `fyolod-dev.service`
with the channel pinned, so it and the release unit never fight over one
socket. `service uninstall` disables and removes the unit and leaves linger as
it was.

This is strictly optional; on-demand start is the supported default.

## Serving a phone or a browser (opt-in)

A phone cannot open a Unix socket and a browser cannot run SSH, so `fyolod`
has one opt-in TCP listener: a WebSocket that carries the same framed protocol,
onto the same socket, with a pairing token in front. Nothing about the SSH path
changes, and a daemon with no WSS bind behaves exactly as it does above.

```sh
ssh my-vps ~/.local/bin/fyolod pair              # mint the token; prints it
ssh my-vps ~/.local/bin/fyolod serve --wss 127.0.0.1:8790 \
      --wss-origin https://box.tailnet.ts.net
```

**The bind is loopback only.** `--wss` parses its value as an IP address and
refuses anything for which `is_loopback()` is false — `0.0.0.0`, `[::]`,
`192.168.1.10`, and a hostname that resolves off loopback are all rejected when
the flag is parsed, before the daemon starts. Put TLS in front of it:

```sh
tailscale serve --bg --https=443 --set-path=/fyolo http://127.0.0.1:8790
```

fyolod never terminates TLS, ships a CA, or pins a certificate. Tailscale
Serve and Caddy are the security team we didn't hire. Serve does not strip its
mount path, so requests arrive as `/fyolo/ws`; fyolod accepts both `/ws` and
`/fyolo/ws` as the same Upgrade, which is why no rewrite rule is needed. Caddy
users who prefer `handle_path /fyolo/*` (which does strip) need no flag change
either.

The default port is **8790** — not the Mac companion's 8787 / 8788, so a Mac
running both does not have them fight.

### The token

`fyolod pair` mints 24 random bytes as base64url and stores them `0600` at
`pair.token`, beside `host.id` in the state dir (`~/.local/state/fyolo` on
Linux), so both survive a reboot — the socket's tmpfs does not. `--wss` never
mints one: a listener that cannot
authenticate is not something to start by accident.

| Command | What it does |
| --- | --- |
| `fyolod pair` | Print the token, minting it on first run. |
| `fyolod pair --json` | The invite as JSON: `url`, `token`, `host_id`, `proto`. |
| `fyolod pair --qr` | The invite as a QR code, drawn in this terminal. |
| `fyolod pair --rotate` | Replace the token. Attached clients detach; no session dies. |
| `fyolod pair --wss-off` | Delete `wss.bind`. The next start is Unix-only. |

`--json` and `--qr` need a reachable URL, and the daemon cannot derive one: the
listener binds loopback on purpose, so the public name lives in `--wss-origin`
or in the tunnel. Both refuse and say so when it is unset rather than print an
invite that points nowhere. Pass `--url https://box.tailnet.ts.net/fyolo/` for
a proxy mounted under a path.

**What the QR costs you: whoever photographs it has full access to the daemon
until you rotate the token.** It is the long-lived pairing secret, not a
short-lived enrollment code, and `fyolod pair --rotate` is the only revocation
there is. Do not screenshare or record a terminal you have just printed one in;
if you do, rotate.

### The durable unit

A flag that lives only on one foreground argv dies on the next crash restart —
the daemon auto-starts as bare `fyolod serve`, and so does the unit
`fyolod service install` writes. So an explicit `--wss` with a token in place
writes `wss.bind` (`0600`) into the state dir, and every later bare start —
including the first one after a reboot — reads it back. That is the whole durable path; the generated unit deliberately puts
nothing about WSS on its command line.

To pin the bind in the unit as well, use a drop-in rather than editing the
generated file — a drop-in survives a later `service install`:

```sh
ssh my-vps systemctl --user edit fyolod
```

```ini
# ~/.config/systemd/user/fyolod.service.d/override.conf
[Service]
Environment=FYOLOD_WSS=127.0.0.1:8790
Environment=FYOLOD_WSS_ORIGIN=https://box.tailnet.ts.net
```

```sh
ssh my-vps ~/.local/bin/fyolod service install
```

The bind is resolved in this order, first valid loopback address winning:
`--wss`, then `FYOLOD_WSS`, then `wss.bind`. With none of the three there is no
TCP listener at all.

Missing `pair.token` splits by where the bind came from:

- **`--wss` on this process's argv** — refuse the whole start, write nothing,
  and say `run fyolod pair`. The operator asked for a listener that cannot
  authenticate.
- **Inherited from `FYOLOD_WSS` or `wss.bind`** — bind the Unix socket, skip
  TCP, log `wss skipped: no pair.token`. A restart must never take the daemon's
  own socket down.

## Reconnect workflow

```sh
fyolo remote list my-vps               # what's running on the VPS
fyolo remote attach my-vps <id|name>   # reattach; Ctrl-\ detaches
fyolo remote attach my-vps build -- npm run dev   # attach-or-create by name
```

Session survives: SSH disconnects, laptop sleep, network drops. It ends only on
`kill` or when its process exits.

## Security model

| Concern | Position |
| --- | --- |
| Listener | Unix socket under `$XDG_RUNTIME_DIR/fyolod/` (or uid-tmp), mode 0600. **No public port.** The opt-in WebSocket binds loopback and nothing else; TLS and reachability are the proxy's job. |
| Auth / ACL | **SSH.** Whoever can `ssh my-vps` as your user can reach your daemon — same trust as a shell. Over the WebSocket it is the `pair.token`, and anyone holding it has the same access. |
| Credentials | Your ssh-agent / `~/.ssh` keys. fyolod stores and transmits none. `pair.token` is the one secret it writes, `0600`, and it never leaves the box except in an invite you hand out. |
| Multi-user | Socket is per-uid and 0600; another user on the box can't connect. A user who can read `pair.token` can, which is why it is `0600` in a `0700` dir. |
| Transport crypto | Entirely SSH's, or entirely the front proxy's. fyolod adds no crypto and no bespoke protocol on the wire beyond the framed session stream inside the channel. |
| Browser CSRF | An `Origin` allowlist (`--wss-origin`), defaulting to same-origin. It constrains pages; the token is what authenticates the pipe. There is no exemption for clients that "look native". |
| Revocation | `fyolod pair --rotate`. It drops every attached WebSocket and refuses the old secret from then on. Sessions keep running — a rotation is a detach, not a kill. |

Do **not** expose the Unix socket over TCP (e.g. `socat`) without adding your
own authentication — the daemon assumes socket access already means "trusted
as this user."

## Testing without a VPS

`remote_smoke_test.py` runs the real `remote` subcommands against the local
binary through a fake-`ssh` shim (drops `-t`/`-o`, runs the command locally),
proving the orchestration and that a session survives "disconnect". Real
cross-arch install needs an actual Linux host; the steps above are the manual
path.
