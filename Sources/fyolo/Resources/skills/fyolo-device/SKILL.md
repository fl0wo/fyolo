---
name: fyolo
description: See and drive the sibling agent sessions running alongside you on this machine via the `fyolod` CLI — list them and their status, start a new agent or plain-terminal session, send a prompt or an answer into one, and set your own status. Use when delegating work to another session, or checking on what other sessions are doing. Do not use merely because a task could run in parallel. Requires running inside a fyolod session (FYOLOD_SESSION_ID set).
---

# Driving sibling sessions (fyolod)

If `FYOLOD_SESSION_ID` is not set in your environment, you are not running
inside a fyolod session — say so and stop instead of trying to drive sessions
you cannot see.

You are running inside a session hosted by `fyolod` on this machine, alongside
other sessions on the same host. Coordinate with them through the `fyolod`
CLI. The installed CLI is the authority on syntax: where this text and
`fyolod --help` disagree, trust the CLI.

**Sessions here are scoped to this machine, not to a project.** The daemon lists
every session it hosts, so read the names and working directories before acting
on one — there is no project filter to lean on.

- `fyolod list --json` — every session on this host, with its status
  (`working` / `idle` / `needs_you` / `done` / `failed` / `unknown`), name, and
  pid. Sessions are addressed by id or by name; both work everywhere a target
  is taken.
- `fyolod send <target> "<text>"` — type into a session as if the user had.
  Use it to answer a sibling that is blocked on a question. `--no-enter` types
  the text without pressing Enter.
- `fyolod create --name <name> --cwd <dir> -- <program> [args…]` — start a new
  session and print its id. With no `--` argv it starts a login shell.
- `fyolod kill <target>` — kill a session and its process group.
- `fyolod set-status "$FYOLOD_SESSION_ID" <state>` — report your own state.
  Valid states are `working`, `idle`, `needs_you`, `done`, `failed`, and
  `unknown`. `--title "<short label>"` sets the label a viewer shows beside the
  session.

## When to use this

- **Delegating.** A task that is genuinely separate work — a long build, an
  independent investigation — can go to a new session so the user watches it in
  its own pane.
- **Supervising.** Before reporting that something is done, check whether a
  sibling you started is still `working` or has gone `needs_you`.
- **Unblocking.** A sibling sitting at `needs_you` is waiting on a human. If you
  can answer it from what you already know, `send` the answer.

Do not spawn a session merely because two things *could* happen at once. A
session the user did not ask for and does not watch is noise.

## What is not available here

Unlike the same skill on a Mac running the fyolo app, there is **no** transcript
reader and **no** project-scoped listing: `fyolod` hosts sessions, and the
project a session belongs to is not yet readable back from it. Do not guess at a
sibling's conversation contents — ask it with `send`, or read what the user
tells you.
