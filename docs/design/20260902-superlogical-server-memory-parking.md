---
title: "Superlogical's server memory model: three levels of parking"
status: draft
type: rfc
created: 2026-09-02
updated: 2026-09-02
related:
  - 20260730-fyolod-session-protocol.md
  - 20260829-feature-cut-after-superlogical-demo.md
  - 20260831-docker-dockerd-lessons.md
---

# Superlogical's server memory model: three levels of parking

> Capture Mitchell Hashimoto's 2026-09 talk on the Superlogical server's memory
> optimizations, and work out which of the ideas apply to fyolod.

Source: <https://x.com/mitchellh/status/2095232081853039041> (11.7-minute audio,
transcribed with Whisper; full transcript at the end). Superlogical is the
closest competitor to fyolod's slice: a self-hosted session host bundled into a
Mac app that also runs standalone on Linux.

## The claims

- **Positioning.** Fully self-hosted, not a service. The Mac app starts a local
  server invisibly, but the same binary runs anywhere — "a server on every
  machine, VPS, and Kubernetes pod you own." The scale argument is AI agents:
  not one person with ten terminals, but hundreds of humans plus hundreds of
  thousands of agents spawning sessions. "If we design for excessive, the low
  end works great."
- **Numbers.** ~400 KB per full terminal vs tmux's ~4–5 MB (10×+), cheaper per
  connected client too. Empty-terminal cost still slightly behind tmux; he says
  he knows why and will match it.

## Mechanism 1 — terminal parking (VT state to disk)

The biggest win. Most terminals are idle, where idle means **no PTY read
bytes** — nothing updating the emulator screen or history. After 60 seconds
idle, the server binary-snapshots the *entire* terminal emulator state to disk
(encrypted, because scrollback holds secrets). A parked terminal costs only the
minimal resources to watch the fd so it can rehydrate.

Details worth noting:

- Parking keys on PTY **reads**, so it works even with clients attached and
  even while the client keeps *writing* keys. Ten idle shells in an open app
  window all park.
- Unparking a 64 MB compressed scrollback: ~200 µs excluding disk, ~20 µs to
  decode — it is a streaming binary protocol, decompressed from disk without
  ever needing the whole snapshot in memory.
- He claims libghostty is the only terminal core inside a multiplexer that
  supports binary snapshotting ("years of work on binary snapshots and
  scrollback compression that doesn't impact IO paying off").

## Mechanism 2 — PTY parking (dedicated thread ⇄ shared poller)

Same finding as Ghostty, re-verified repeatedly: the fastest PTY I/O is **one
dedicated OS thread blocked on `read()`** — putting many PTY fds into
kqueue/epoll/io_uring takes a noticeable latency and throughput hit. But at
server scale (thousands to tens of thousands of PTYs) the kernel-thread
overhead — stack, accounting — dominates. So:

- Idle PTY, **or** no client currently observing it → tear down the dedicated
  thread and move the fd into one shared kqueue/epoll thread.
- Cost of the shared poller: ~5–10% I/O throughput — acceptable exactly when no
  human is watching the output.
- Activity (a PTY read) promotes it back to a dedicated thread.

## Mechanism 3 — client buffer parking

Each attached client gets kilobytes of throughput buffers to pipeline data
toward the network. Once a client goes idle after initial sync, the buffers are
freed outright and reallocated on the next burst. Mostly network-bound anyway,
but it cuts both memory and active-CPU cost.

## Bonus — attach never wakes a parked terminal

On attach, the client is repopulated from the binary snapshot. For a parked
terminal, the snapshot is **streamed from disk directly to the client** — the
server never rehydrates. A client hammering attach/detach against a parked
terminal costs the server nothing but disk streaming.

## What this means for fyolod

fyolod today matches Superlogical's baseline shape — one PTY per session, a
dedicated read path (`fyolod/src/pty.rs`), sidecar VT for
snapshot-at-boundaries — and the anti-100× invariant already forbids the
per-frame work that makes tmux expensive. The parking tiers are the delta:

1. **Snapshot-from-disk on attach is protocol-compatible.** "State sync only at
   boundaries" already means attach = snapshot; serving that snapshot from a
   parked on-disk image instead of a live VT changes nothing on the wire. This
   is the most fyolod-shaped idea in the talk.
2. **PTY parking is the cheap first step.** Demoting idle/unobserved PTYs from
   dedicated threads to one shared poller needs no snapshot format, no
   encryption story, and directly addresses the "hundreds of agent sessions on
   one box" load. The 5–10% observed-throughput tradeoff maps cleanly onto the
   existing observer/write-token model — we know exactly when nobody is
   watching.
3. **Full VT parking is gated on the terminal core.** Binary-snapshotting the
   whole emulator state is a libghostty capability claim; whether our pinned
   libghostty-swift/ghostty revision exposes usable serialize/deserialize for
   the host-side sidecar VT is the open question to answer before designing
   anything. Encryption-at-rest for scrollback (secrets!) comes with it.
4. **Idle definition transfers verbatim.** "Idle = no PTY reads, writes don't
   count" is the right key for us too — an agent session waiting on a prompt
   with the user occasionally typing stays parked.

None of this is committed work; this doc records the mechanisms so a future
memory/scale pass on fyolod starts from here instead of from the tweet.

## Full transcript (Whisper, lightly annotated)

Mishears: "super logical" = Superlogical, "Tmuck" = tmux, "P2I"/"PQI" = PTY,
"libgoC"/"LibGhosty" = libghostty, "Ghosty" = Ghostty, "KQ"/"E-pol" =
kqueue/epoll, "invented system" = event system, "theoristic" = heuristic,
"IOTroup" = I/O throughput, "sprawl-back" = scrollback.

All right, let's talk about this. So I've given a ton of demos of this
Superlogical macOS app, but I want to talk more about the Superlogical server.
The server is where the actual terminal sessions run. I want to start by being
clear that when I say server, it's a fully self-hosted thing. It's not a
service. It's built into the Mac app. So when you start the Mac app as a new
user, we start a server on your machine for you and it's all magical and
invisible, but you can also take the server and run it anywhere. It runs on
Linux. It's not tied to the Mac app. And I think we've shown a lot of the care
that we've put into the Mac client app. And I want to show some demos of the
care — or some data, I should say — of the care that we've put into the server
as well.

So first, I want to start by talking about how this server is meant to run
anywhere and everywhere. Our vision of where this is going is that you will run
a Superlogical server on every machine you own, on every server component that
you or your company has, on every Kubernetes pod potentially, anywhere that you
need remote access, you will probably be running a server. And so this needs to
be safe. It needs to be scalable. It needs to be resource friendly. There's a
lot of properties there that are very different from a client app. And so I
want to start by talking about that. And I'm going to focus it first on the
memory usage. There's I/O throughput, CPU usage, security, some other stuff I
want to talk about, but today we're just going to talk about the memory usage
and some of the cool things that we're doing there.

I just want to mention, I'm not going to read this post, but I will just hit on
this one paragraph. I want to talk about why this level of scale matters, or
why I think that the scale that we're building for is different from what
multiplexers have done in the past. And surprise surprise, the big reason is
AI. Even if you don't use AI at all, I think this just makes the software
better for you as a human. But the big reason is AI agents love compute. They
want a place to execute code. We're seeing this in the rise of sandbox
providers and so on. And so agents are spinning up an unprecedented number of
terminal sessions, executable sessions, SSH sessions. And attaching to them,
right? And so we need to think about this level of scale. It's not a
multiplexer for one person attaching to one server at a time with 10 terminal
sessions on that server. It's dozens of people, hundreds of people, with an
order of magnitude — hundreds of thousands of agents or more — spawning even
more terminals than that. And maybe your reaction to that is: that is
excessive. Well, if we design for excessive, then the low end will work really
great. So this is all really good for everybody. OK, so that's why it's
important to me.

I'm going to let you look at the numbers on your own. I want to talk about some
of the cool ways we achieved some of this. So obviously, tmux starts at a lower
number than Superlogical. But this is where things start getting interesting.
The memory cost per full terminal is an order of magnitude in favor of
Superlogical. We're at the 400 kilobyte level. They are more than 10 times
more, at the 4, nearing 5 megabyte level. For empty terminals, they are a
little bit less, but I know what that is, and we'll be able to match that. I
think this is the more interesting thing, this, and then the per-client cost of
us being cheaper per connected client. Again, need to get that lower too, but
that's pretty good for now.

But I want to talk about some of the cool things we do in order to save memory
with terminals. So three or four things I want to talk about. One, I want to
talk about what I just called parking. Some people might call it hydrating /
dehydrating. I call it parking and unparking. The biggest optimization we make
is that for terminals, most terminals at a certain point are idle. They're not
getting any more bytes. When I say idle, I'm really talking about read bytes on
the PTY — bytes that would update the terminal emulator screen and history
state. Most are idle. And so if a terminal is idle for 60 seconds, what we do
with our multiplexer is we park it. And what that means is we take a binary
snapshot of the entire terminal emulator state and put it to disk. There's
encryption and other security involved there — there's often secrets in
scrollback, so we have to protect against that; we'll talk about that another
time — but we park this to disk. And so the cost of a terminal that's parked to
disk is only basically the minimal resources to monitor the file descriptor so
that it could unpark, rehydrate, when activity comes back.

And a really interesting fun part of this is it is really only on PTY read. You
could still type keys and send data — write to the PTY. But if that isn't
updating the actual terminal emulator state — the PTY read — we don't need to
unpark this. So this parking terminals works even when clients are attached. If
I have my Superlogical app open and I have 10 terminals, but all 10 terminals
are sitting on idle shells, all 10 terminals are going to be parked. They're
going to cost nothing in memory. And so that's one of the biggest benefits we
have. And as far as I know, the libghostty that we're built on is the only
terminal technology within a multiplexer that supports binary snapshotting —
and we have some custom wrappers around it. But this is how we achieve this. We
binary-snapshot the entire terminal emulator state. And then when a PTY read
comes back, when data comes back, when some event happens that we need to
rehydrate it, we unpark it. And this is really bound by your disk speed —
because even for a 64 megabyte (which is much bigger than 10,000 lines, by the
way) — even for a 64 megabyte full compressed scrollback, it takes us about 200
microseconds to unpark that, not counting the disk speed. So once we have the
data, we can decompress and decode streaming from disk. We don't have to wait
for all of it to be in memory. This is designed to be a streaming binary
protocol. It only takes about 20 microseconds. So this is super, super fast. So
basically, we aggressively park and unpark terminals to save memory.

And so the second thing we park: we also park the PTY. What does this mean?
Well, we discovered in Ghostty — so you can actually look at Ghostty as a
reference implementation — we discovered that the fastest way to get I/O
performance is to put each PTY in its own dedicated OS thread blocked on the
read syscall. We found early on, and we've re-verified this time and time
again, that if you throw multiple PTY fds into kqueue or epoll or io_uring,
there is a very noticeable hit to latency, to I/O throughput. You cannot put
these all into an event system. It's better to just block on the read with an
OS thread. And so that's what we do in Superlogical as well. The problem — this
is what we don't do in Ghostty — the problem is that OS threads are expensive,
relatively. If you're talking about building a system like the Superlogical
server that's not meant for a desktop scale of terminals, but a server scale of
terminals, which could be thousands, tens of thousands — the OS thread
overhead, the stack size, and just the accounting around a kernel thread gets
very, very expensive. And so what we do as well is: if the PTY is idle, or if a
client isn't attached to it and maximum throughput isn't important, then we
park the PTY. And what that means is we have a single OS thread that does use
kqueue and epoll. And we move the file descriptor out from its dedicated OS
thread, tear that down, and we put it into the event system — slightly higher
latency, way lower resource usage as the number of file descriptors increases.
And so we run this heuristic in a couple of different ways, which I already
mentioned. One, if the terminal gets parked, we throw that into the centralized
poller. Two, if there's no clients observing the terminal at that moment, we
also move it — because you get about a 5% to 10% hit in I/O throughput, but
that's worth it when you're not looking at it. That 5% to 10% speed isn't going
to matter as much when a human isn't judging it. So we also move it and
optimize for memory in that case. So that's the second parking.

And then the third level of parking — so we did the terminal, the PTY — we have
client parking. So when a client attaches, in order to optimize the speed at
which a client could read data from the server, we have a bunch of buffers, so
that we could just continually move stuff along the chain. It adds up — it's
kilobytes of buffers. When a client is mostly idle after a period of time,
after the initial synchronization and so on, we park the buffers, which is
basically: we free them. We free the buffers, and then the next time there's a
bunch of activity, we reallocate them. This is pretty much predominantly
dominated by network costs, but it does lower memory usage a lot, and it does
lower CPU usage while active.

So the thing about performance is that everything is related; everything's a
trade-off or has to be taken in consideration to something else. So you can't
just get memory — it's usually like you're trading memory for CPU or memory for
I/O or something. And so all of these little choices are sort of on the
performance triangle of what we're trading off. And so it's hard to really talk
about the system holistically when we're just talking about one benchmark here
with some memory. So I will talk about the others later, but those are sort of
the three things that we do. And I'll keep it at three, just because we're at
10 minutes now.

I think this is really interesting. This is something that I've never seen
another multiplexer do. I think it's something that's only possible due to the
really hard work that we've put into libghostty — making binary snapshots and
scrollback compression that doesn't impact I/O. All this work we've thought
about for years is paying off in a big way here. And that's really cool.

I will mention one more cool detail. When a client connects — I gave a video on
X before about this — when a client connects, we send it the binary snapshot.
That's how it repopulates the client. And so if a client connects to a parked
terminal, we actually stream the binary snapshot from disk directly to the
client. We don't need to unpark the terminal because a client attached. So if
you have a client that's just hammering attach, attach, attach — on, off, on,
off — the server just stays on disk and we're just streaming from disk, which
is pretty cool.

So there's a little overview. I hope to talk more about the different
components of Superlogical in the future. And this is sort of the intro into
the server side.
