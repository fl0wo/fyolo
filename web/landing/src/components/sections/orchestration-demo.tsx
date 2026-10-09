"use client";

import { useEffect, useRef, useState } from "react";
import { useInView } from "@/lib/use-in-view";
import { AgentIcon } from "@/components/agent-icons";
import { cn } from "@/lib/utils";

// The orchestration section's demo is the app itself rather than a diagram of
// it: a Fyolo window whose left pane is the real sidebar, and whose content
// area is the layout the app actually gets used in (see the hero captures) —
// the driver session's shell holding the left column, and a stack of the
// agents it spawned filling the right one.
//
// One state machine runs all of it. The first `fyolo sessions spawn` splits
// the content area in two; every spawn after that adds a pane to the right
// column, so the fleet builds up on screen as the driver types. Each spawn
// also lands a session row in the sidebar, and the row and its pane then carry
// the same status (the app's rotating nine-dot working mark, a green ring when
// the turn finishes, an orange ring when the agent stops to ask) until the
// result prints back into the transcript.
//
// Chrome is the app's: traffic lights over the sidebar, the window's title
// block (folder over branch) left-aligned atop the content, status on a row's
// leading mark rather than a trailing dot (Sidebar/SidebarView.swift).
//
// One deliberate liberty: `fyolo sessions spawn` starts a session, it does not
// group it into a split — grouping is a user action ("Group with"). The demo
// shows them grouped because the whole point is watching an agent work while
// another drives it.
//
// Falls back to a static done-state window for SSR, screen readers, and
// reduced motion.

type TranscriptLine = {
  text?: string;
  prompt?: boolean;
  // Output color semantics: plain (undefined) = neutral status text, "done" =
  // the same green the sidebar's done ring uses, so one state reads the same
  // everywhere. needs-you moments stay neutral in the transcript — only the
  // ring and the agent pane go orange (colored text read as noise here).
  tone?: "done";
  blank?: boolean;
  id?: number; // stable key so a freshly-pushed line animates in exactly once
};

type Status = "idle" | "working" | "needs-you" | "done";

type Frame = {
  lines: TranscriptLine[];
  typing: string | null;
  statuses: Status[]; // index-aligned with SESSIONS
  // The session whose pane is focused — the one just spawned. null before the
  // first spawn, when the content area is a single, unsplit shell.
  active: number | null;
};

// Status colors are the app's, not the section's: green done / orange needs-you
// are the sidebar's only color channel, and this is that sidebar.
const DONE = "#27c93f"; // brand-green — matches StatusRing's .green
const NEEDS_YOU = "#ffb764"; // brand-amber — matches StatusRing's .orange

// The driving session: the one whose shell holds the left column. It stays
// working for the whole run — it is the thing typing.
const DRIVER = { agent: "Claude Code", title: "ship v0.22.0" };

// The four sessions it spawns, in pipeline order — top-to-bottom in both the
// sidebar and the right column. A row's title is the prompt the CLI spawned it with, which is what
// the app shows as a session's title, and `tools` is what that agent's own
// pane shows itself doing. Output lines use the sessions-watch text shape:
// link  [status]  detail; sessions are addressed by fyolo://session/<uuid>
// since 8b38709 (the <agent>@<id> handle is gone). `interaction` (codex only)
// shows a needs-you round trip: the agent asks, the driver answers, it resumes.
type Tool = { verb: string; target: string; result: string };

type Session = {
  agent: string;
  /** The agent as you'd name it on the command line, shown in its own pane. */
  cli: string;
  title: string;
  cmd: string;
  started: string;
  /** Present-tense verb for the agent pane's working line. */
  activity: string;
  elapsed: string;
  tools: readonly Tool[];
  /** Tool-call glyphs. Claude Code prints a filled bullet over a `⌊` result
   *  line; the rest of the fleet uses the common `•` / `└` pair. */
  bullet: string;
  sub: string;
  interaction?: {
    needsYou: string;
    answer: string;
    sent: string;
    /** The question as the agent's own pane puts it. */
    question: string;
    reply: string;
  };
  done: string;
  /** The agent pane's closing line once the turn settles. */
  outcome: string;
};

const SESSIONS: readonly Session[] = [
  {
    agent: "Claude Code",
    cli: "claude",
    title: "plan the auth refactor",
    cmd: 'fyolo sessions spawn "plan the auth refactor" --agent claude',
    started: "fyolo://session/9b3e11d0  [working]  planning",
    activity: "Planning",
    elapsed: "0m 41s",
    tools: [
      { verb: "Read", target: "Auth/TokenStore.swift", result: "412 lines" },
      { verb: "Grep", target: '"refreshToken"', result: "29 matches" },
    ],
    bullet: "●",
    sub: "⌊",
    done: "fyolo://session/9b3e11d0  [done]  7 steps -> PLAN.md",
    outcome: "7 steps -> PLAN.md",
  },
  {
    agent: "Codex",
    cli: "codex",
    title: "implement PLAN.md",
    cmd: 'fyolo sessions spawn "implement PLAN.md" --agent codex',
    started: "fyolo://session/7c1f2a4e  [working]  building",
    activity: "Building",
    elapsed: "1m 06s",
    tools: [
      { verb: "Edit", target: "TokenStore.swift", result: "+180 -52" },
      { verb: "Shell", target: "swift build", result: "succeeded" },
    ],
    bullet: "•",
    sub: "└",
    interaction: {
      needsYou: "fyolo://session/7c1f2a4e  [needs-you]  Run swift test? (y/n)",
      answer: 'fyolo sessions send 7c1f2a4e "y"',
      sent: "sent to fyolo://session/7c1f2a4e",
      question: "Run swift test? (y/n)",
      reply: "y",
    },
    done: "fyolo://session/7c1f2a4e  [done]  +412 -128, tests pass",
    outcome: "+412 -128, tests pass",
  },
  {
    agent: "DeepSeek",
    cli: "deepseek",
    title: "review the diff",
    cmd: 'fyolo sessions spawn "review the diff" --agent deepseek',
    started: "fyolo://session/5a77c0e2  [working]  reviewing",
    activity: "Reviewing",
    elapsed: "0m 28s",
    tools: [
      { verb: "Read", target: "PLAN.md", result: "7 steps" },
      { verb: "Diff", target: "Sources/Auth", result: "12 files" },
    ],
    bullet: "•",
    sub: "└",
    done: "fyolo://session/5a77c0e2  [done]  2 nits, 0 blockers",
    outcome: "2 nits, 0 blockers",
  },
  {
    agent: "Grok",
    cli: "grok",
    title: "security scan, then tag v0.22.0",
    cmd: 'fyolo sessions spawn "security scan, then tag v0.22.0" --agent grok',
    started: "fyolo://session/d4e6b209  [working]  scanning",
    activity: "Scanning",
    elapsed: "0m 52s",
    tools: [
      { verb: "Scan", target: "Sources", result: "0 findings" },
      { verb: "Shell", target: "git tag v0.22.0", result: "tagged" },
    ],
    bullet: "•",
    sub: "└",
    done: "fyolo://session/d4e6b209  [done]  clean, tagged v0.22.0",
    outcome: "clean, tagged v0.22.0",
  },
];

// The project's worktrees, shown the way the sidebar shows them: quiet folder
// rows under the session list, no status of their own.
const WORKTREES = [
  "feat/auth-refactor",
  "fix/session-title",
  "feat/remote-tree",
  "chore/deps",
] as const;

// Static fallback / screen-reader copy: the whole pipeline in its done state.
const DONE_SUMMARY: readonly TranscriptLine[] = SESSIONS.map((s) => ({
  tone: "done" as const,
  text: s.done,
}));

const STATIC_FRAME: Frame = {
  lines: DONE_SUMMARY.slice(-3),
  typing: null,
  statuses: SESSIONS.map(() => "done"),
  active: SESSIONS.length - 1,
};

// Rolling transcript window, sized to the shell's column at its tallest.
const MAX_LINES = 8;

function sleep(ms: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}

export function OrchestrationDemo() {
  const { ref, inView } = useInView<HTMLDivElement>("80px");
  const [frame, setFrame] = useState<Frame>(STATIC_FRAME);

  useEffect(() => {
    if (!inView) return;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

    let cancelled = false;
    const patch = (p: Partial<Frame>) =>
      setFrame((f) => (cancelled ? f : { ...f, ...p }));

    const buf: TranscriptLine[] = [];
    let lineSeq = 0;
    const commit = () => patch({ lines: buf.slice(-MAX_LINES) });
    const push = (line: TranscriptLine) => {
      // Stable id so React keeps each rendered line and only the newly pushed
      // one mounts (and plays its fade-in) — buffer shifts never replay it.
      buf.push({ ...line, id: ++lineSeq });
      commit();
    };

    const type = async (cmd: string) => {
      // The command (input) is typed a little at a time, like a keystroke feed.
      // Small chunks keep it smooth without a re-render per character; kept
      // deliberately unhurried.
      for (let i = 0; i <= cmd.length; i += 2) {
        if (cancelled) return;
        patch({ typing: cmd.slice(0, i) });
        await sleep(34);
      }
      patch({ typing: null });
      push({ prompt: true, text: cmd });
    };

    const play = async () => {
      while (!cancelled) {
        buf.length = 0;
        const statuses: Status[] = SESSIONS.map(() => "idle");
        patch({ lines: [], typing: null, statuses: [...statuses], active: null });
        await sleep(700);
        if (cancelled) return;

        for (let i = 0; i < SESSIONS.length; i++) {
          const session = SESSIONS[i];
          const last = i === SESSIONS.length - 1;

          // Command first, then the session exists: its sidebar row arrives and
          // its pane opens under the shell, both already working.
          await type(session.cmd);
          if (cancelled) return;
          statuses[i] = "working";
          patch({ statuses: [...statuses], active: i });
          // The result arrives all at once (a whole line), after a short beat.
          await sleep(420);
          push({ text: session.started });
          await sleep(session.interaction ? 1400 : 2100);
          if (cancelled) return;

          if (session.interaction) {
            push({ text: session.interaction.needsYou });
            statuses[i] = "needs-you";
            patch({ statuses: [...statuses] });
            await sleep(1800);
            if (cancelled) return;
            // Blank separator so the answer command starts a fresh block, like
            // every other typed command.
            push({ blank: true });
            await type(session.interaction.answer);
            if (cancelled) return;
            await sleep(320);
            push({ text: session.interaction.sent });
            statuses[i] = "working";
            patch({ statuses: [...statuses] });
            await sleep(1700);
            if (cancelled) return;
          }

          push({ tone: "done", text: session.done });
          statuses[i] = "done";
          patch({ statuses: [...statuses] });
          push({ blank: true });
          await sleep(last ? 4200 : 1600);
        }
      }
    };

    void play();
    return () => {
      cancelled = true;
    };
  }, [inView]);

  // Every session that exists yet, in spawn order — the right column's panes.
  const spawned = SESSIONS.map((session, index) => ({ session, index })).filter(
    ({ index }) => frame.statuses[index] !== "idle",
  );
  const split = spawned.length > 0;

  return (
    <div ref={ref} className="relative">
      {/* The window. Sidebar tone sits a step above the terminal's near-black,
          the way the app's source list sits above its surfaces; the inset top
          hairline plus the cast shadow are what make it read as a real macOS
          window rather than a flat panel. */}
      <div className="flex h-[25rem] overflow-hidden rounded-2xl border border-white/10 bg-[#1b1b21] shadow-[inset_0_1px_0_0_rgba(255,255,255,0.08),0_28px_60px_-24px_rgba(0,0,0,0.8)] md:h-[27rem] lg:h-[28rem]">
        {/* The sidebar only opens once the window is wide enough for the
            terminal beside it to hold a full command line unwrapped — below
            that it folds away, which is the app's own collapsed-source-list
            state rather than a web-only compromise. */}
        <aside
          aria-hidden="true"
          className="hidden w-[34%] max-w-[16.5rem] shrink-0 flex-col lg:flex"
        >
          <div className="flex items-center gap-2 px-3.5 py-3">
            <TrafficLights />
            <SidebarToggleGlyph className="ml-1.5" />
            <PlusGlyph className="ml-auto" />
          </div>

          <div className="min-h-0 flex-1 overflow-hidden px-2 pt-1">
            <ProjectRow name="fyolo" />
            <ul className="flex flex-col">
              <SessionRow
                agent={DRIVER.agent}
                title={DRIVER.title}
                status="working"
              />
              {SESSIONS.map((session, i) => {
                const status = frame.statuses[i] ?? "idle";
                if (status === "idle") return null;
                return (
                  <SessionRow
                    key={session.title}
                    agent={session.agent}
                    title={session.title}
                    status={status}
                    // Selection follows the pane below: the app highlights the
                    // session you are looking at, and that is the one whose
                    // terminal just opened.
                    selected={i === frame.active}
                    // Rows arrive as the driver spawns them, so each one fades
                    // in once — the same reveal the transcript lines use.
                    className="line-in"
                  />
                );
              })}
            </ul>
            <ul className="mt-1 flex flex-col">
              {WORKTREES.map((branch) => (
                <WorktreeRow key={branch} branch={branch} />
              ))}
            </ul>
          </div>
        </aside>

        {/* The content area: the driver session's shell on the left, and — once
            something has been spawned — the split holding the agents' own
            terminals on the right. The window's title block (the session's
            folder over its branch) sits at the top, the way the app titles a
            window. */}
        <div className="flex min-w-0 flex-1 flex-col border-white/[0.07] bg-[#0b0b0d] lg:border-l">
          <div className="flex items-start gap-3 px-4 pb-2 pt-3 sm:px-5">
            <div className="flex lg:hidden">
              <TrafficLights />
            </div>
            <div className="min-w-0 leading-tight">
              <p className="truncate text-[12px] font-medium text-foreground/85">
                fyolo
              </p>
              <p className="truncate text-[10.5px] text-muted-foreground">main</p>
            </div>
            <InspectorGlyph className="ml-auto shrink-0" />
          </div>

          {/* Screen-reader copy of the pipeline's outcome; the animated panes
              re-render too often to be useful aloud. */}
          <pre className="sr-only">
            {DONE_SUMMARY.map((l) => `${l.text}\n`).join("")}
          </pre>

          <div
            aria-hidden="true"
            className="flex min-h-0 flex-1 px-4 pb-4 sm:px-5 sm:pb-5"
          >
            {/* The driver's shell. It keeps the left column once the split
                opens, so it wraps its longer commands there exactly like a real
                terminal in a narrow pane — the link lines have no soft break
                points to fall on. */}
            <div
              className={cn(
                "min-w-0",
                split ? "w-full md:w-[55%] md:shrink-0" : "flex-1",
              )}
            >
              <pre className="whitespace-pre-wrap break-words font-mono text-[11px] leading-[1.6] md:text-[11.5px] xl:text-[12px] xl:leading-[1.65]">
                {frame.lines.map((line, i) =>
                  line.blank ? (
                    <span key={line.id ?? i}>{"\n"}</span>
                  ) : (
                    <span
                      key={line.id ?? i}
                      className={
                        // Output lines fade in on arrival; typed prompt lines
                        // are already animated by the typewriter, so they don't.
                        line.prompt ? "block" : "line-in block"
                      }
                    >
                      {line.prompt ? (
                        <>
                          <span className="select-none text-slate-400">$ </span>
                          <span className="text-slate-50">{line.text}</span>
                        </>
                      ) : (
                        <span
                          style={
                            line.tone === "done" ? { color: DONE } : undefined
                          }
                          className={line.tone === "done" ? "" : "text-slate-300"}
                        >
                          {line.text}
                        </span>
                      )}
                    </span>
                  ),
                )}
                {frame.typing !== null && (
                  <span className="block">
                    <span className="select-none text-slate-400">$ </span>
                    <span className="text-slate-50">{frame.typing}</span>
                    <span className="demo-cursor text-slate-50/80">▋</span>
                  </span>
                )}
              </pre>
            </div>

            {/* The right column. It wipes open on the first spawn, then each
                later spawn adds a pane under the last — the same beat as the
                row arriving in the sidebar, and the layout the app is actually
                used in. Every pane is keyed by its agent, so it mounts once and
                plays its own open. Below md the window is too narrow to hold
                two columns of terminal text, so the split waits for the room. */}
            {split && (
              <div className="split-in ml-3 hidden min-w-0 flex-1 flex-col border-l border-white/[0.07] pl-3 md:flex">
                {spawned.map(({ session, index }, position) => (
                  <div
                    key={session.cli}
                    className={cn(
                      "pane-in min-h-0 flex-1",
                      position > 0 && "mt-2 border-t border-white/[0.07] pt-2",
                    )}
                  >
                    <AgentPane
                      session={session}
                      status={frame.statuses[index] ?? "idle"}
                    />
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}

/* ----------------------------------------------------------- agent pane --- */

// One spawned agent working in its own pane. The shape is a stylized agent-CLI
// session rather than any one vendor's exact chrome: who it is and what it was
// asked, the tool calls it is making, and a closing line — held to four rows,
// because four of these share the right column and each one still has to read.
// The closing line carries the same working / needs-you / done language as the
// sidebar row beside it.
function AgentPane({
  session,
  status,
}: {
  session: Session;
  status: Status;
}) {
  return (
    <div className="min-h-0 font-mono text-[10px] leading-[1.6] lg:text-[10.5px]">
      <p className="flex items-center gap-1.5 truncate">
        <AgentIcon
          name={session.agent}
          size={11}
          color={session.agent !== "Kimi"}
          className="text-foreground/80"
        />
        <span className="shrink-0 text-foreground/80">{session.cli}</span>
        <span className="truncate text-muted-foreground/70">
          {session.title}
        </span>
      </p>
      {/* Result inline after the call rather than on its own `└` row: at four
          panes to a column there is no height to spend on a line each. */}
      {session.tools.map((tool) => (
        <p key={tool.verb + tool.target} className="truncate">
          <span className="select-none text-slate-500">{session.bullet} </span>
          <span className="text-slate-200">{tool.verb} </span>
          <span className="text-slate-400">{tool.target}</span>
          <span className="text-slate-500">
            {" "}
            {session.sub} {tool.result}
          </span>
        </p>
      ))}

      {status === "needs-you" && session.interaction && (
        <p className="truncate" style={{ color: NEEDS_YOU }}>
          <span className="select-none">? </span>
          {session.interaction.question}
          <span className="demo-cursor"> ▋</span>
        </p>
      )}
      {status === "working" && (
        <p className="flex items-center gap-1.5 truncate">
          <WorkingIndicator />
          <span className="text-slate-300">{session.activity}</span>
          <span className="truncate text-slate-500">
            ({session.elapsed} · esc to interrupt)
          </span>
        </p>
      )}
      {status === "done" && (
        <p className="truncate" style={{ color: DONE }}>
          <span className="select-none">✓ </span>
          {session.outcome}
        </p>
      )}
    </div>
  );
}

/* --------------------------------------------------------------- chrome --- */

function TrafficLights() {
  return (
    <div className="flex shrink-0 items-center gap-[6px]">
      <span className="size-[11px] rounded-full bg-brand-red" />
      <span className="size-[11px] rounded-full bg-brand-amber" />
      <span className="size-[11px] rounded-full bg-brand-green" />
    </div>
  );
}

function SidebarToggleGlyph({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.7}
      className={cn("size-[15px] text-muted-foreground", className)}
    >
      <rect x="3" y="4" width="18" height="16" rx="3" />
      <path d="M9.5 4v16" />
    </svg>
  );
}

function PlusGlyph({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.9}
      strokeLinecap="round"
      className={cn("size-[15px] text-muted-foreground", className)}
    >
      <path d="M12 5v14M5 12h14" />
    </svg>
  );
}

function InspectorGlyph({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.7}
      className={cn("size-[15px] text-muted-foreground", className)}
    >
      <rect x="3" y="4" width="18" height="16" rx="3" />
      <path d="M14.5 4v16" />
    </svg>
  );
}

/* -------------------------------------------------------------- sidebar --- */

function FolderGlyph({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.7}
      strokeLinejoin="round"
      className={cn("shrink-0", className)}
    >
      <path d="M3 7.5A1.5 1.5 0 0 1 4.5 6h4l2 2.5h7A1.5 1.5 0 0 1 19 10v7a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 3 17z" />
    </svg>
  );
}

function ProjectRow({ name }: { name: string }) {
  return (
    <div className="flex items-center gap-2 px-2 py-[5px] text-[12.5px] text-foreground/85">
      <FolderGlyph className="size-[15px] text-muted-foreground" />
      <span className="truncate">{name}</span>
    </div>
  );
}

function SessionRow({
  agent,
  title,
  status,
  selected = false,
  className,
}: {
  agent: string;
  title: string;
  status: Status;
  selected?: boolean;
  className?: string;
}) {
  return (
    <li
      className={cn(
        // Sessions indent under their project header, and selection is a soft
        // full-width fill — no outline (SidebarRowHighlight).
        "flex items-center gap-1.5 rounded-[7px] py-[5px] pl-6 pr-2",
        selected && "bg-white/[0.09]",
        className,
      )}
    >
      <span className="relative grid size-4 shrink-0 place-items-center">
        {status === "working" ? (
          <WorkingIndicator />
        ) : (
          // Kimi's color mark is blue-on-white and washes out on the dark
          // sidebar, so it uses the mono (currentColor) variant instead.
          <AgentIcon
            name={agent}
            size={12}
            color={agent !== "Kimi"}
            className="text-foreground/80"
          />
        )}
        {/* The resting status is a ring around the leading mark — green when the
            turn just finished, orange when the agent is blocked on you — never a
            trailing dot. Sized well past the icon so it reads as a halo rather
            than an outline on the mark, and an overlay so it never shifts the
            row. */}
        <span
          className="pointer-events-none absolute size-5 rounded-full border-[1.5px] transition-colors duration-300"
          style={{
            borderColor:
              status === "done"
                ? DONE
                : status === "needs-you"
                  ? NEEDS_YOU
                  : "transparent",
          }}
        />
      </span>
      <span
        className={cn(
          "truncate text-[12.5px]",
          selected ? "text-foreground" : "text-foreground/80",
        )}
      >
        {title}
      </span>
    </li>
  );
}

function WorktreeRow({ branch }: { branch: string }) {
  return (
    <li className="flex items-center gap-1.5 py-[5px] pl-6 pr-2 text-[12.5px] text-muted-foreground">
      <FolderGlyph className="size-4" />
      <span className="truncate">{branch}</span>
      <svg
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth={2}
        strokeLinecap="round"
        className="ml-auto size-3 shrink-0 opacity-60"
      >
        <line x1="6" y1="3" x2="6" y2="15" />
        <circle cx="18" cy="6" r="3" />
        <circle cx="6" cy="18" r="3" />
        <path d="M18 9a9 9 0 0 1-9 9" />
      </svg>
    </li>
  );
}

// The eight perimeter cells of a 3×3 grid in clockwise order, as (column, row)
// with the center at (1,1) — the ring the comet travels, matching the app's
// WorkingIndicator (Shared/FyoloShared/SessionStatus.swift). Geometry is the
// app's too: 2.5pt dots on a 3.6pt pitch, over a steady half-ink center.
const RING: readonly (readonly [number, number])[] = [
  [0, 0],
  [1, 0],
  [2, 0],
  [2, 1],
  [2, 2],
  [1, 2],
  [0, 2],
  [0, 1],
];
const DOT = 2.5;
const PITCH = 3.6;
const PERIOD = 1.1;

function WorkingIndicator() {
  return (
    <span className="relative block size-[13px] shrink-0 text-foreground">
      {[[1, 1] as const, ...RING].map(([column, row], i) => (
        <span
          key={`${column}-${row}`}
          className={cn(
            "absolute rounded-full bg-current",
            // The center dot is the steady anchor; only the ring animates.
            i === 0 ? "opacity-50" : "working-dot",
          )}
          style={{
            width: DOT,
            height: DOT,
            left: `calc(50% + ${(column - 1) * PITCH - DOT / 2}px)`,
            top: `calc(50% + ${(row - 1) * PITCH - DOT / 2}px)`,
            animationDelay: i === 0 ? undefined : `${-((i - 1) / 8) * PERIOD}s`,
          }}
        />
      ))}
    </span>
  );
}
