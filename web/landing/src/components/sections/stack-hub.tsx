"use client";

import { HugeiconsIcon } from "@hugeicons/react";
import { Folder01Icon } from "@hugeicons/core-free-icons";
import { cn } from "@/lib/utils";
import { useInView } from "@/lib/use-in-view";
import { AgentIcon } from "@/components/agent-icons";
import { GitHubMark } from "@/components/section-label";
import { DONE, NEEDS_YOU, TrafficLights } from "@/components/app-chrome";

// The hero's picture of the pitch: every tool a project touches plugs into one
// Fyolo terminal. Tools sit on either side with a wire into the window; in
// turn, a tool's chip fires, a comet runs its wire, the port on the window's
// edge flares, and the matching line in the TUI lights — so the reader watches
// GitHub, Linear, Docker and the agents land in the same place.
//
// The motion lives in globals.css (.hub-*) and moves only transform and
// opacity, so it never costs a layout or a repaint per frame; it pauses while
// the hero is scrolled away.

// Brand marks from Simple Icons 16.34.0 (CC0 1.0, simpleicons.org), drawn in
// currentColor like the agent marks beside them.
const brandPaths = {
  linear:
    "M2.886 4.18A11.982 11.982 0 0 1 11.99 0C18.624 0 24 5.376 24 12.009c0 3.64-1.62 6.903-4.18 9.105L2.887 4.18ZM1.817 5.626l16.556 16.556c-.524.33-1.075.62-1.65.866L.951 7.277c.247-.575.537-1.126.866-1.65ZM.322 9.163l14.515 14.515c-.71.172-1.443.282-2.195.322L0 11.358a12 12 0 0 1 .322-2.195Zm-.17 4.862 9.823 9.824a12.02 12.02 0 0 1-9.824-9.824Z",
  docker:
    "M13.983 11.078h2.119a.186.186 0 00.186-.185V9.006a.186.186 0 00-.186-.186h-2.119a.185.185 0 00-.185.185v1.888c0 .102.083.185.185.185m-2.954-5.43h2.118a.186.186 0 00.186-.186V3.574a.186.186 0 00-.186-.185h-2.118a.185.185 0 00-.185.185v1.888c0 .102.082.185.185.185m0 2.716h2.118a.187.187 0 00.186-.186V6.29a.186.186 0 00-.186-.185h-2.118a.185.185 0 00-.185.185v1.887c0 .102.082.185.185.186m-2.93 0h2.12a.186.186 0 00.184-.186V6.29a.185.185 0 00-.185-.185H8.1a.185.185 0 00-.185.185v1.887c0 .102.083.185.185.186m-2.964 0h2.119a.186.186 0 00.185-.186V6.29a.185.185 0 00-.185-.185H5.136a.186.186 0 00-.186.185v1.887c0 .102.084.185.186.186m5.893 2.715h2.118a.186.186 0 00.186-.185V9.006a.186.186 0 00-.186-.186h-2.118a.185.185 0 00-.185.185v1.888c0 .102.082.185.185.185m-2.93 0h2.12a.185.185 0 00.184-.185V9.006a.185.185 0 00-.184-.186h-2.12a.185.185 0 00-.184.185v1.888c0 .102.083.185.185.185m-2.964 0h2.119a.185.185 0 00.185-.185V9.006a.185.185 0 00-.184-.186h-2.12a.186.186 0 00-.186.186v1.887c0 .102.084.185.186.185m-2.92 0h2.12a.185.185 0 00.184-.185V9.006a.185.185 0 00-.184-.186h-2.12a.185.185 0 00-.184.185v1.888c0 .102.082.185.185.185M23.763 9.89c-.065-.051-.672-.51-1.954-.51-.338.001-.676.03-1.01.087-.248-1.7-1.653-2.53-1.716-2.566l-.344-.199-.226.327c-.284.438-.49.922-.612 1.43-.23.97-.09 1.882.403 2.661-.595.332-1.55.413-1.744.42H.751a.751.751 0 00-.75.748 11.376 11.376 0 00.692 4.062c.545 1.428 1.355 2.48 2.41 3.124 1.18.723 3.1 1.137 5.275 1.137.983.003 1.963-.086 2.93-.266a12.248 12.248 0 003.823-1.389c.98-.567 1.86-1.288 2.61-2.136 1.252-1.418 1.998-2.997 2.553-4.4h.221c1.372 0 2.215-.549 2.68-1.009.309-.293.55-.65.707-1.046l.098-.288Z",
  vitest:
    "M11.545 23.3a.613.613 0 0 1-.895.197L.252 15.936A.61.61 0 0 1 0 15.439V6.325c0-.502.569-.792.975-.497l6.358 4.624c.594.433 1.432.25 1.793-.39L14.393.7a.62.62 0 0 1 .535-.314h8.455a.613.613 0 0 1 .537.916z",
} as const;

function BrandMark({ brand }: { brand: keyof typeof brandPaths }) {
  return (
    <svg
      viewBox="0 0 24 24"
      width={17}
      height={17}
      fill="currentColor"
      aria-hidden="true"
    >
      <path d={brandPaths[brand]} />
    </svg>
  );
}

type Tone = "working" | "needs-you" | "done" | "info";

type Tool = {
  name: string;
  side: "left" | "right";
  // Firing order. Sources alternate sides, so the eye ping-pongs across the
  // window instead of reading one column top to bottom.
  slot: number;
  icon: React.ReactNode;
  command: string;
  status: string;
  detail: string;
  tone: Tone;
};

const tools: readonly Tool[] = [
  {
    name: "Claude",
    side: "left",
    slot: 0,
    icon: <AgentIcon name="Claude Code" size={17} />,
    command: "claude",
    status: "working",
    detail: "refactoring auth middleware",
    tone: "working",
  },
  {
    name: "Codex",
    side: "left",
    slot: 2,
    icon: <AgentIcon name="Codex" size={17} />,
    command: "codex",
    status: "needs you",
    detail: "approve the db migration?",
    tone: "needs-you",
  },
  {
    name: "Files",
    side: "left",
    slot: 4,
    icon: (
      <HugeiconsIcon
        icon={Folder01Icon}
        size={17}
        strokeWidth={1.8}
        aria-hidden="true"
      />
    ),
    command: "files",
    status: "2 modified",
    detail: "src/auth/session.ts +42 −7",
    tone: "info",
  },
  {
    name: "Vitest",
    side: "left",
    slot: 6,
    icon: <BrandMark brand="vitest" />,
    command: "vitest",
    status: "148 passed",
    detail: "0 failed · 1.9s",
    tone: "done",
  },
  {
    name: "GitHub",
    side: "right",
    slot: 1,
    icon: <GitHubMark className="h-[17px] w-[17px]" />,
    command: "github",
    status: "PR #142",
    detail: "3/3 checks passed",
    tone: "done",
  },
  {
    name: "Linear",
    side: "right",
    slot: 3,
    icon: <BrandMark brand="linear" />,
    command: "linear",
    status: "ENG-311",
    detail: "In Progress → In Review",
    tone: "info",
  },
  {
    name: "Docker",
    side: "right",
    slot: 5,
    icon: <BrandMark brand="docker" />,
    command: "docker",
    status: "3 running",
    detail: "api · postgres · redis",
    tone: "done",
  },
];

const SLOT_SECONDS = 1.1;

const toneColor: Record<Tone, string> = {
  working: "var(--hub-accent)",
  "needs-you": NEEDS_YOU,
  done: DONE,
  info: "rgba(255,255,255,0.55)",
};

function slotStyle(tool: Tool): React.CSSProperties {
  return {
    "--hub-delay": `${tool.slot * SLOT_SECONDS}s`,
    "--hub-cycle": `${tools.length * SLOT_SECONDS}s`,
  } as React.CSSProperties;
}

// No backdrop blur on the chips: they sit over the live WebGL aurora, and a
// backdrop filter there re-blurs on every shader frame.
function ToolChip({ tool }: { tool: Tool }) {
  return (
    <div
      style={slotStyle(tool)}
      className="hub-chip flex shrink-0 items-center gap-2 rounded-xl border border-white/10 bg-[#0d0a14]/90 px-3 py-2 text-sm font-medium text-foreground"
    >
      <span className="text-foreground/85">{tool.icon}</span>
      {tool.name}
    </div>
  );
}

// The wire from a chip to the window, ending in a port on the window's edge.
// The comet always runs toward the terminal, so right-side wires are mirrored.
function Wire({ tool }: { tool: Tool }) {
  return (
    <div
      aria-hidden="true"
      style={slotStyle(tool)}
      className={cn(
        "relative hidden h-6 flex-1 items-center lg:flex",
        tool.side === "right" && "-scale-x-100",
      )}
    >
      <div className="h-px w-full bg-gradient-to-r from-white/[0.06] to-white/20" />
      <div className="absolute inset-0 overflow-hidden">
        <span className="hub-comet" />
      </div>
      <span className="hub-port" />
    </div>
  );
}

function ToolColumn({ side }: { side: Tool["side"] }) {
  return (
    <div className="flex flex-wrap justify-center gap-2.5 lg:flex-col lg:flex-nowrap lg:gap-4">
      {tools.map((tool) =>
        tool.side === side ? (
          <div
            key={tool.name}
            className={cn(
              "flex items-center",
              side === "right" && "flex-row-reverse",
            )}
          >
            <ToolChip tool={tool} />
            <Wire tool={tool} />
          </div>
        ) : null,
      )}
    </div>
  );
}

function Terminal() {
  return (
    <div
      className={cn(
        "relative z-10 overflow-hidden rounded-xl border border-white/10 bg-black text-left font-mono",
        "shadow-[inset_0_1px_0_0_rgba(255,255,255,0.07),0_30px_60px_-24px_rgba(0,0,0,0.9),0_0_48px_-12px_rgba(168,85,247,0.35)]",
      )}
    >
      <div className="relative flex h-9 items-center border-b border-white/[0.08] bg-black px-3.5">
        <TrafficLights />
        <span className="absolute inset-x-0 text-center text-[11px] text-white/45">
          fyolo — ~/code/api
        </span>
      </div>

      <div className="px-3 pb-3 pt-3 text-[11px] leading-[1.9] sm:px-4 sm:text-[12.5px]">
        <div className="flex items-center justify-between px-1.5 text-white/40">
          <span>~/code/api</span>
          <span>⎇ main ↑2</span>
        </div>
        <ul className="mt-1.5">
          {tools.map((tool) => (
            <li
              key={tool.name}
              style={slotStyle(tool)}
              className="hub-row grid grid-cols-[1.1rem_3.9rem_1fr] items-center gap-x-2 rounded-md px-1.5 sm:grid-cols-[1.1rem_4.4rem_6.4rem_1fr]"
            >
              <span
                className="h-1.5 w-1.5 justify-self-center rounded-full"
                style={{ background: toneColor[tool.tone] }}
              />
              <span className="text-white/85">{tool.command}</span>
              <span style={{ color: toneColor[tool.tone] }}>{tool.status}</span>
              <span className="hidden truncate text-white/45 sm:block">
                {tool.detail}
              </span>
            </li>
          ))}
        </ul>
        <div className="mt-2 border-t border-white/[0.06] px-1.5 pt-2 text-white/85">
          <span className="text-[color:var(--hub-accent)]">❯</span>{" "}
          <span className="text-white/50">one terminal, every tool</span>
          <span className="demo-cursor ml-1 inline-block h-[1.05em] w-[0.55em] translate-y-[0.18em] bg-white/70" />
        </div>
      </div>
    </div>
  );
}

export function StackHub() {
  const { ref, inView } = useInView<HTMLElement>();
  return (
    <figure
      ref={ref}
      data-hub-paused={inView ? undefined : ""}
      aria-label="GitHub, Linear, Docker, Vitest, your files, Claude and Codex all connected to one Fyolo terminal."
      className="grid w-full items-center gap-6 lg:grid-cols-[minmax(0,1fr)_minmax(0,2fr)_minmax(0,1fr)] lg:gap-0"
    >
      <ToolColumn side="left" />
      <Terminal />
      <ToolColumn side="right" />
    </figure>
  );
}
