import { AgentIcon } from "@/components/agent-icons";
import {
  BranchGlyph,
  DONE,
  FolderGlyph,
  MockWindow,
  NEEDS_YOU,
  ServerGlyph,
  TrafficLights,
  WorkingIndicator,
} from "@/components/app-chrome";
import { cn } from "@/lib/utils";

// One small animated mock per feature card. Each is the real surface drawn in
// DOM — the sidebar, the palette, the inspector, the Markdown reader, the SSH
// host list, the worktree tree — not a screenshot and not a diagram.
//
// The motion is pure CSS (see the `mock-*` keyframes in globals.css): no timers,
// no React state, nothing re-rendering per frame, and every loop is compositor
// work (opacity / transform / color). Six of these share a page with the
// orchestration demo, so none of them may cost a render.

const ROW = "flex items-center gap-1.5 rounded-md px-1.5 py-1 text-[10px]";

/* ------------------------------------------------------------ 1. sidebar --- */

// Every session's status in one column. The three states cycle on staggered
// delays so the card shows the whole language — spinner, green ring, orange
// ring — without anything having to happen on a timer.
const FLEET = [
  { agent: "Claude Code", title: "ship v0.22.0", phase: 0 },
  { agent: "Codex", title: "implement PLAN.md", phase: 1 },
  { agent: "DeepSeek", title: "review the diff", phase: 2 },
  { agent: "Grok", title: "security scan", phase: 3 },
] as const;

export function SidebarMock() {
  return (
    <MockWindow className="h-[9.5rem] flex-col">
      <div className="flex items-center gap-2 px-2.5 py-2">
        <TrafficLights size={7} />
      </div>
      <div className="px-2">
        <div className="flex items-center gap-1.5 px-1.5 py-1 text-[10px] text-foreground/80">
          <FolderGlyph className="size-3 text-muted-foreground" />
          <span>fyolo</span>
        </div>
        <ul className="flex flex-col">
          {FLEET.map((session, i) => (
            <li
              key={session.title}
              className={cn(ROW, "pl-5", i === 1 && "bg-white/[0.08]")}
            >
              <span className="relative grid size-3.5 shrink-0 place-items-center">
                {/* Both marks are always mounted and cross-faded by the cycle,
                    so a row swapping to the spinner costs no layout. */}
                <span
                  className="mock-status-spinner absolute"
                  style={{ animationDelay: `${session.phase * -1.5}s` }}
                >
                  <WorkingIndicator size={11} />
                </span>
                <span
                  className="mock-status-mark"
                  style={{ animationDelay: `${session.phase * -1.5}s` }}
                >
                  <AgentIcon name={session.agent} size={11} color />
                </span>
                <span
                  className="mock-status-ring pointer-events-none absolute size-[17px] rounded-full border-[1.5px]"
                  style={{ animationDelay: `${session.phase * -1.5}s` }}
                />
              </span>
              <span className="truncate text-foreground/80">
                {session.title}
              </span>
            </li>
          ))}
        </ul>
      </div>
    </MockWindow>
  );
}

/* ---------------------------------------------------- 2. command palette --- */

// ⇧⌘P over a running session. The query types itself, the selection walks the
// results, and the terminal behind it repaints as each theme is highlighted —
// the palette's live preview, which is the part that is hard to photograph.
const THEMES = ["Tokyo Night", "Catppuccin Mocha", "Rosé Pine"] as const;

export function PaletteMock() {
  return (
    <MockWindow className="mock-theme relative h-[9.5rem] flex-col">
      {/* The session underneath, tinted by whichever theme is highlighted. */}
      <div className="flex items-center gap-2 px-2.5 py-2">
        <TrafficLights size={7} />
      </div>
      <div className="px-3 font-mono text-[9px] leading-[1.7]">
        <p className="mock-theme-ink">$ swift build</p>
        <p className="mock-theme-ink opacity-70">Compiling fyolo…</p>
      </div>

      {/* The palette itself, floating over the session. */}
      <div className="absolute inset-x-3 top-11 rounded-lg border border-white/[0.14] bg-[#16161b]/95 shadow-[0_12px_28px_-12px_rgba(0,0,0,0.9)] backdrop-blur-md">
        <div className="flex items-center gap-1.5 border-b border-white/[0.08] px-2 py-1.5">
          <svg
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth={2}
            className="size-2.5 shrink-0 text-muted-foreground"
          >
            <circle cx="11" cy="11" r="7" />
            <path d="m20 20-3.5-3.5" />
          </svg>
          <span className="mock-type overflow-hidden whitespace-nowrap text-[10px] text-foreground/90">
            theme
          </span>
          <span className="demo-cursor -ml-1 text-[10px] text-foreground/60">
            ▏
          </span>
        </div>
        <ul className="p-1">
          {THEMES.map((theme, i) => (
            <li
              key={theme}
              className={cn(ROW, "mock-option gap-2 py-[3px]")}
              style={{ animationDelay: `${i * 1.6}s` }}
            >
              <span className="size-2 shrink-0 rounded-[3px] bg-current opacity-70" />
              <span className="truncate text-foreground/85">{theme}</span>
            </li>
          ))}
        </ul>
      </div>
    </MockWindow>
  );
}

/* ---------------------------------------------------------- 3. inspector --- */

// Files beside the terminal: the tree on the left, the file open on the right.
// The selection walks the tree and the editor repaints with it.
const TREE: readonly { name: string; folder?: boolean }[] = [
  { name: "Sources", folder: true },
  { name: "TokenStore.swift" },
  { name: "Models.swift" },
  { name: "PLAN.md" },
];

export function InspectorMock() {
  return (
    <MockWindow className="h-[9.5rem]">
      <div className="flex w-[47%] shrink-0 flex-col border-r border-white/[0.07]">
        <div className="flex items-center gap-2 px-2.5 py-2">
          <TrafficLights size={7} />
        </div>
        <ul className="px-1.5">
          {TREE.map((entry, i) => (
            <li
              key={entry.name}
              className={cn(
                ROW,
                "gap-1.5 text-[9px]",
                !entry.folder && "mock-option pl-4",
              )}
              style={
                entry.folder ? undefined : { animationDelay: `${(i - 1) * 1.6}s` }
              }
            >
              {entry.folder ? (
                <FolderGlyph className="size-3 text-muted-foreground" />
              ) : (
                <span className="size-3 shrink-0" />
              )}
              <span className="truncate text-foreground/75">{entry.name}</span>
            </li>
          ))}
        </ul>
      </div>
      {/* The file open beside it, syntax-highlighted. */}
      <div className="min-w-0 flex-1 px-2.5 py-2 font-mono text-[9px] leading-[1.75]">
        <p className="truncate">
          <span className="text-[#c792ea]">struct</span>{" "}
          <span className="text-[#82aaff]">TokenStore</span>
          <span className="text-slate-400"> {"{"}</span>
        </p>
        <p className="truncate pl-2">
          <span className="text-[#c792ea]">let</span>{" "}
          <span className="text-slate-300">keychain</span>
          <span className="text-slate-400">:</span>{" "}
          <span className="text-[#82aaff]">Keychain</span>
        </p>
        <p className="truncate pl-2">
          <span className="text-[#c792ea]">func</span>{" "}
          <span className="text-[#82aaff]">refresh</span>
          <span className="text-slate-400">() {"{"}</span>
        </p>
        <p className="truncate pl-4 text-slate-500">// …</p>
        <p className="truncate pl-2 text-slate-400">{"}"}</p>
        <p className="truncate text-slate-400">{"}"}</p>
      </div>
    </MockWindow>
  );
}

/* ------------------------------------------------------------ 4. markdown --- */

// A README opened in the reader. The pane cross-fades between the source and
// what Fyolo renders from it — GFM tables and task lists included.
export function MarkdownMock() {
  return (
    <MockWindow className="relative h-[9.5rem] flex-col">
      <div className="flex items-center gap-2 px-2.5 py-2">
        <TrafficLights size={7} />
        <span className="truncate text-[9px] text-muted-foreground">
          PLAN.md
        </span>
      </div>

      {/* Source. */}
      <div className="mock-fade-a absolute inset-x-0 bottom-0 top-7 px-3 font-mono text-[9px] leading-[1.8]">
        <p className="text-[#82aaff]"># Auth refactor</p>
        <p className="text-slate-400">Move token storage into the keychain.</p>
        <p className="mt-1 text-slate-300">
          <span className="text-[#c792ea]">- [x]</span> audit call sites
        </p>
        <p className="text-slate-300">
          <span className="text-[#c792ea]">- [ ]</span> migrate `TokenStore`
        </p>
        <p className="text-slate-300">
          <span className="text-[#c792ea]">- [ ]</span> drop the shim
        </p>
      </div>

      {/* Rendered. */}
      <div className="mock-fade-b absolute inset-x-0 bottom-0 top-7 px-3 text-[10px] leading-[1.7]">
        <p className="border-b border-white/[0.1] pb-0.5 text-[12px] font-semibold text-foreground">
          Auth refactor
        </p>
        <p className="mt-1 text-[9px] text-muted-foreground">
          Move token storage into the keychain.
        </p>
        <ul className="mt-1 space-y-[3px] text-[9px] text-foreground/85">
          {[true, false, false].map((checked, i) => (
            <li key={i} className="flex items-center gap-1.5">
              <span
                className={cn(
                  "grid size-2.5 shrink-0 place-items-center rounded-[3px] border",
                  checked
                    ? "border-transparent text-[#08080a]"
                    : "border-white/25",
                )}
                style={checked ? { backgroundColor: DONE } : undefined}
              >
                {checked && (
                  <svg
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    strokeWidth={4}
                    className="size-1.5"
                  >
                    <path d="m5 13 5 5L20 7" />
                  </svg>
                )}
              </span>
              <span className={cn(checked && "text-muted-foreground")}>
                {["audit call sites", "migrate TokenStore", "drop the shim"][i]}
              </span>
            </li>
          ))}
        </ul>
      </div>
    </MockWindow>
  );
}

/* --------------------------------------------------------------- 5. remote --- */

// Settings ▸ SSH, reading the hosts out of your own `~/.ssh/config`. The probe
// runs down the list and each host comes back reachable.
const HOSTS = [
  { name: "devbox", tint: "#5ac8fa" },
  { name: "vps-fra", tint: "#bf5af2" },
  { name: "mac-mini", tint: "#ffd60a" },
] as const;

export function RemoteMock() {
  return (
    <MockWindow className="h-[9.5rem] flex-col">
      <div className="flex items-center gap-2 px-2.5 py-2">
        <TrafficLights size={7} />
        <span className="truncate text-[9px] text-muted-foreground">
          ~/.ssh/config
        </span>
      </div>
      <ul className="px-2">
        {HOSTS.map((host, i) => (
          <li key={host.name} className={cn(ROW, "gap-2 py-[5px]")}>
            <ServerGlyph className="size-3 text-muted-foreground" />
            <span className="truncate text-foreground/80">{host.name}</span>
            <span
              className="ml-auto size-1.5 shrink-0 rounded-full"
              style={{ backgroundColor: host.tint }}
            />
            {/* The Test Connection probe: dots, then reachable. */}
            <span className="relative grid w-11 shrink-0 place-items-center">
              <span
                className="mock-fade-a absolute text-[9px] text-muted-foreground"
                style={{ animationDelay: `${i * 0.5}s` }}
              >
                ···
              </span>
              <span
                className="mock-fade-b absolute whitespace-nowrap text-[9px]"
                style={{ animationDelay: `${i * 0.5}s`, color: DONE }}
              >
                ✓ 24ms
              </span>
            </span>
          </li>
        ))}
      </ul>
    </MockWindow>
  );
}

/* ------------------------------------------------------------ 6. worktrees --- */

// Worktrees read straight from git, nested under the project as branch folders
// with their own sessions. Each one opens in turn.
const WORKTREES: readonly {
  branch: string;
  session?: string;
  status?: "working" | "done" | "needs-you";
}[] = [
  { branch: "feat/auth-refactor", session: "implement PLAN.md", status: "working" },
  { branch: "fix/session-title", session: "reproduce the bug", status: "needs-you" },
];

export function WorktreeMock() {
  return (
    <MockWindow className="h-[9.5rem] flex-col">
      <div className="flex items-center gap-2 px-2.5 py-2">
        <TrafficLights size={7} />
      </div>
      <div className="px-2">
        <div className="flex items-center gap-1.5 px-1.5 py-1 text-[10px] text-foreground/80">
          <FolderGlyph className="size-3 text-muted-foreground" />
          <span>fyolo</span>
        </div>
        <ul className="flex flex-col">
          {WORKTREES.map((tree, i) => (
            <li key={tree.branch}>
              <div className={cn(ROW, "gap-1.5 pl-4 text-muted-foreground")}>
                <BranchGlyph className="size-2.5 opacity-70" />
                <span className="truncate">{tree.branch}</span>
              </div>
              {/* The session living in that worktree, revealed in turn. */}
              {tree.session && (
              <div
                className={cn(ROW, "mock-open gap-1.5 pl-8")}
                style={{ animationDelay: `${i * 1.5}s` }}
              >
                <span className="relative grid size-3 shrink-0 place-items-center">
                  {tree.status === "working" ? (
                    <WorkingIndicator size={10} />
                  ) : (
                    <span
                      className="size-1.5 rounded-full"
                      style={{
                        backgroundColor:
                          tree.status === "done" ? DONE : NEEDS_YOU,
                      }}
                    />
                  )}
                </span>
                <span className="truncate text-foreground/70">
                  {tree.session}
                </span>
              </div>
              )}
            </li>
          ))}
        </ul>
      </div>
    </MockWindow>
  );
}
