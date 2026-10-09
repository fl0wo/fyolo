import { cn } from "@/lib/utils";

// Each supported agent's terminal UI, drawn in DOM instead of screenshotted.
//
// Every layout here was taken from a real capture of that CLI running inside
// Fyolo (the files these replaced, public/agent/*.png): the banner blocks, the
// key/value headers, the hint rows and the status lines are what each agent
// actually prints on launch — the same reason the orchestration demo draws the
// app's chrome rather than photographing it.
//
// Two things are deliberately not verbatim. Paths and session ids are
// genericised (a capture carries the author's home directory), and dated
// promos are dropped — a banner announcing a model launch is stale the week
// after it ships, and these panels are permanent.
//
// Sizing: the whole panel scales off the container's width in `cqw`, with every
// child in `em`. The showcase renders these at anything from a phone column to
// half a desktop card, and a screenshot's one virtue — scaling as one piece —
// had to survive the port.

const PATH = "~/Documents/GitHub/fyolo";

// OpenCode's launch wordmark, transcribed character for character from the
// running CLI. The lone `▄` on the first row is the `d`'s ascender.
const OPENCODE_MARK = [
  "                                 ▄",
  "█▀▀█ █▀▀█ █▀▀█ █▀▀▄ █▀▀▀ █▀▀█ █▀▀█ █▀▀█",
  "█  █ █  █ █▀▀▀ █  █ █    █  █ █  █ █▀▀▀",
  "▀▀▀▀ █▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀",
];

/* ---------------------------------------------------------------- shell --- */

// Fyolo's own window around the agent, matching the captures: traffic lights,
// the sidebar toggle, the folder-over-branch title block, the inspector toggle.
function AgentWindow({
  children,
  className,
}: {
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <div
      className={cn(
        "flex h-full w-full flex-col overflow-hidden rounded-[clamp(10px,2.2cqw,22px)] bg-[#1c1c1e] font-mono text-[#e6e6ea]",
        className,
      )}
      style={{ fontSize: "2.35cqw", lineHeight: 1.55 }}
    >
      <div className="flex shrink-0 items-center gap-[1em] px-[1.1em] py-[0.9em]">
        <div className="flex shrink-0 items-center gap-[0.5em]">
          <span className="size-[0.85em] rounded-full bg-brand-red" />
          <span className="size-[0.85em] rounded-full bg-brand-amber" />
          <span className="size-[0.85em] rounded-full bg-brand-green" />
        </div>
        <PaneGlyph className="ml-[0.4em] w-[1.5em] text-white/45" />
        <div className="ml-[0.6em] min-w-0 leading-tight">
          <p className="truncate text-[0.95em] font-semibold text-white">
            fyolo
          </p>
          <p className="truncate text-[0.8em] text-white/45">main</p>
        </div>
        <PaneGlyph className="ml-auto w-[1.5em] shrink-0 text-white/45" />
      </div>
      <div className="min-h-0 flex-1 px-[1.4em] pb-[1em]">{children}</div>
    </div>
  );
}

function PaneGlyph({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.8}
      className={cn("shrink-0", className)}
      style={{ aspectRatio: "1 / 1" }}
    >
      <rect x="3" y="5" width="18" height="14" rx="3" />
      <path d="M10 5v14" />
    </svg>
  );
}

// The rule-bounded input row most of these CLIs draw at the bottom.
function RuledInput({
  char = "❯",
  rule = "rgba(255,255,255,0.22)",
}: {
  char?: string;
  rule?: string;
}) {
  return (
    <div
      className="mt-auto border-y py-[0.5em]"
      style={{ borderColor: rule }}
    >
      <p className="flex items-center gap-[0.6em] text-white/70">
        <span>{char}</span>
        <span className="inline-block h-[1.05em] w-[0.6em] bg-white/80" />
      </p>
    </div>
  );
}

// A boxed input, for the agents that draw a border around theirs.
function BoxedInput({
  char,
  placeholder,
  border = "rgba(255,255,255,0.22)",
  children,
}: {
  char?: string;
  placeholder?: string;
  border?: string;
  children?: React.ReactNode;
}) {
  return (
    <div
      className="rounded-[0.35em] border px-[0.8em] py-[0.55em]"
      style={{ borderColor: border }}
    >
      {children ?? (
        <p className="flex items-center gap-[0.6em] text-white/55">
          {char && <span>{char}</span>}
          {placeholder ? (
            <span>{placeholder}</span>
          ) : (
            <span className="inline-block h-[1.05em] w-[0.6em] bg-white/70" />
          )}
        </p>
      )}
    </div>
  );
}

// Terminal art — block letters, braille — laid out a cell at a time rather than
// as lines of text. A `<pre>` would hold together only where the mono face
// covers those blocks itself; where it falls back, the substituted glyphs carry
// their own advance width and the picture shears. A fixed grid can't.
function CharGrid({
  lines,
  cell = 0.6,
  className,
}: {
  lines: readonly string[];
  /**
   * Cell width in `em`, against the mono face's own ~0.6em advance. The row
   * height and the glyph scale off it together, so a larger cell draws larger
   * art rather than the same art spaced further apart.
   */
  cell?: number;
  className?: string;
}) {
  const columns = Math.max(...lines.map((line) => [...line].length));
  return (
    <span
      aria-hidden
      className={cn("grid", className)}
      style={{
        // Sized in the grid's own `em`, so the cell stays one mono advance
        // wide and one terminal row tall whatever scale it is drawn at.
        fontSize: `${cell / 0.6}em`,
        gridTemplateColumns: `repeat(${columns}, 0.6em)`,
        gridAutoRows: "1.02em",
        lineHeight: 1,
      }}
    >
      {lines.flatMap((line, y) =>
        [...line].map((char, x) => <span key={`${x}-${y}`}>{char}</span>),
      )}
    </span>
  );
}

/* ----------------------------------------------------------------- claude --- */

// Claude Code leads with its pixel mark beside a three-line header, and closes
// on the permission-mode footer.
function ClaudeTui() {
  return (
    <AgentWindow>
      <div className="flex h-full flex-col">
        <div className="flex items-start gap-[1.1em] pt-[0.4em]">
          <pre className="shrink-0 text-[0.95em] leading-[1.15] text-[#c37b62]">
            {"▐▛███▜▌\n▝▜█████▛▘\n  ▘▘ ▝▝"}
          </pre>
          <div className="min-w-0">
            <p>
              <span className="font-semibold text-white">Claude Code</span>{" "}
              <span className="text-white/40">v2.1.220</span>
            </p>
            <p className="truncate text-white/55">Opus 5 · Claude Max</p>
            <p className="truncate text-white/40">{PATH}</p>
          </div>
        </div>

        <p className="mt-[1em] truncate">
          <span className="text-white/45">❯ </span>
          <span className="text-white/85">/fyolo list the sibling sessions</span>
        </p>
        <p className="mt-[0.7em] truncate text-white/70">
          <span className="text-[#c37b62]">⏺</span> Running 1 shell command…
        </p>
        <p className="truncate pl-[1.2em] text-white/40">
          ⎿ $ fyolo sessions list --json
        </p>
        <p className="mt-[0.6em] text-white/55">Idle (3)</p>
        {[
          ["7c1f2a4e…", "codex", "implement PLAN.md"],
          ["5a77c0e2…", "deepseek", "review the diff"],
          ["d4e6b209…", "grok", "security scan"],
        ].map(([id, agent, title]) => (
          <p key={id} className="truncate text-white/45">
            <span className="text-white/30">- </span>
            {id} <span className="text-white/60">{agent}</span> — {title}
          </p>
        ))}
        <p className="mt-[0.6em] truncate text-white/50">
          <span className="text-[#c37b62]">✻</span> Cooked for 11s
        </p>

        <RuledInput />
        <p className="pt-[0.5em] text-[0.95em] text-white/35">
          ⏸ manual mode on · ? for shortcuts · ← for agents
        </p>
      </div>
    </AgentWindow>
  );
}

/* ------------------------------------------------------------------ codex --- */

// Codex opens with a bordered header box, a tip, a usage note, and the
// highlighted composer over its model/cwd status line.
function CodexTui() {
  const MODELS = [
    ["1.", "gpt-5.6-sol (current)", "Latest frontier agentic coding model."],
    ["2.", "gpt-5.6-terra", "Balanced model for everyday work."],
    ["3.", "gpt-5.6-luna", "Fast and affordable coding model."],
    ["4.", "gpt-5.5", "Frontier model for complex work."],
  ];
  return (
    <AgentWindow>
      <div className="flex h-full flex-col pt-[0.5em]">
        <div className="rounded-[0.3em] border border-white/[0.18] px-[0.9em] py-[0.7em]">
          <p className="truncate">
            <span className="text-white/60">{">_"}</span>{" "}
            <span className="font-semibold text-white">OpenAI Codex</span>{" "}
            <span className="text-white/40">(v0.147.0)</span>
          </p>
          <p className="mt-[0.5em] flex gap-[0.6em] truncate">
            <span className="w-[5.2em] shrink-0 text-white/40">model:</span>
            <span className="truncate">
              <span className="text-white">gpt-5.6-sol xhigh</span>{" "}
              <span className="text-[#7ec9a6]">/model</span>{" "}
              <span className="text-white/40">to change</span>
            </span>
          </p>
        </div>

        <p className="mt-[1em] text-white/85">Select Model and Effort</p>
        <div className="mt-[0.5em]">
          {MODELS.map(([n, name, desc], i) => (
            <p key={n} className="truncate">
              <span className={i === 0 ? "text-[#7ec9a6]" : "text-transparent"}>
                ›{" "}
              </span>
              <span className={i === 0 ? "text-white" : "text-white/70"}>
                {n} {name}
              </span>{" "}
              <span className="text-white/35">{desc}</span>
            </p>
          ))}
        </div>
        <p className="mt-[0.7em] truncate text-white/35">
          Press enter to confirm or esc to go back
        </p>

        <p className="mt-auto truncate text-[0.92em] text-[#7ec9a6]">
          gpt-5.6-sol xhigh fast{" "}
          <span className="text-[#7ec9a6]/60">· {PATH}</span>
        </p>
      </div>
    </AgentWindow>
  );
}

/* --------------------------------------------------------------- opencode --- */

// OpenCode centres its block wordmark over a teal-edged composer, with the
// hint row and status bar it draws underneath.
function OpenCodeTui() {
  return (
    <AgentWindow>
      <div className="flex h-full flex-col">
        <div className="flex flex-1 items-center justify-center">
          {/* The wordmark is block characters, not type — this is the exact art
              OpenCode prints, down to the ascender floating over the `d`. Each
              row is split at the halfway letter because the CLI draws `open`
              dim and `code` bright. */}
          <pre
            className="leading-[1.05]"
            style={{ fontSize: "0.86em" }}
            aria-hidden
          >
            {OPENCODE_MARK.map((row, i) => (
              <div key={i}>
                <span className="text-white/40">{row.slice(0, 19)}</span>
                <span className="text-white/90">{row.slice(19)}</span>
              </div>
            ))}
          </pre>
        </div>
        <div className="border-l-[0.18em] border-[#4fd6c9] bg-white/[0.06] px-[0.9em] py-[0.7em]">
          <p className="truncate text-white/45">
            Ask anything… <span className="text-white/60">&quot;Fix broken tests&quot;</span>
          </p>
          <p className="mt-[0.6em] truncate">
            <span className="text-[#4fd6c9]">Sisyphus</span>
            <span className="text-white/50"> - </span>
            <span className="text-[#8b9cf7]">Ultraworker</span>
            <span className="text-white/35"> · </span>
            <span className="text-white/85">GPT-5.5</span>{" "}
            <span className="text-white/40">OpenAI</span>
            <span className="text-white/35"> · </span>
            <span className="text-[#e0a458]">medium</span>
          </p>
        </div>
        <p className="mt-[0.5em] truncate text-right text-[0.92em]">
          <span className="text-white/85">tab</span>{" "}
          <span className="text-white/40">agents</span>{" "}
          <span className="ml-[0.6em] text-white/85">ctrl+p</span>{" "}
          <span className="text-white/40">commands</span>
        </p>
        <p className="mt-auto truncate text-[0.92em] text-white/40">
          <span className="text-[#e0a458]">•</span>{" "}
          <span className="text-[#e0a458]">Tip</span> Add .md files to
          .opencode/commands/ for reusable prompts
        </p>
        <p className="mt-[0.6em] flex items-center gap-[0.6em] truncate text-[0.9em] text-white/35">
          <span className="truncate">{PATH}:main</span>
          <span className="text-[#5fb47f]">⊙ 4 MCP</span>
          <span className="ml-auto shrink-0">1.17.20</span>
        </p>
      </div>
    </AgentWindow>
  );
}

/* -------------------------------------------------------------------- amp --- */

// Amp fills the pane with a dot-matrix sphere over a boxed composer that
// carries its reasoning level and cwd on the border.
function AmpTui() {
  return (
    <AgentWindow>
      <div className="flex h-full flex-col">
        <p className="pt-[0.6em] text-center text-[#b5c96a]">Welcome to Amp</p>
        <div className="flex flex-1 items-center justify-center gap-[2em] overflow-hidden">
          <AmpSphere />
          {/* Amp lists its two entry points beside the mark on launch. */}
          <div className="shrink-0 text-white/45">
            <p>
              <span className="text-white/75">ctrl+o</span> for commands
            </p>
            <p>
              <span className="text-white/75">?</span> for shortcuts
            </p>
          </div>
        </div>
        <div className="relative mt-[0.8em]">
          <div className="h-[3.2em] rounded-[0.25em] border border-white/25" />
          <span className="absolute -top-[0.75em] right-[0.8em] bg-[#1c1c1e] px-[0.4em] text-[0.92em] text-[#6fcf97]">
            medium
          </span>
          <span className="absolute -bottom-[0.75em] right-[0.8em] max-w-[90%] truncate bg-[#1c1c1e] px-[0.4em] text-[0.92em] text-white/45">
            {PATH} (main)
          </span>
        </div>
      </div>
    </AgentWindow>
  );
}

// The sphere, laid out deterministically: a dot per grid cell, sized and
// dimmed by its distance from the centre so the matrix reads as a lit ball.
// Deterministic on purpose — a random pattern would differ between the server
// render and the client one.
function AmpSphere() {
  const COLUMNS = 34;
  const ROWS = 19;
  const cells = [];
  for (let y = 0; y < ROWS; y++) {
    for (let x = 0; x < COLUMNS; x++) {
      const nx = (x - (COLUMNS - 1) / 2) / (COLUMNS / 2);
      const ny = (y - (ROWS - 1) / 2) / (ROWS / 2);
      const r = Math.sqrt(nx * nx + ny * ny);
      if (r > 1) {
        cells.push(<span key={`${x}-${y}`} />);
        continue;
      }
      // Light falls from the upper left, so dots grow and brighten toward it.
      const lit = Math.max(0, 1 - Math.hypot(nx + 0.45, ny + 0.5) / 1.5);
      const size = 0.14 + lit * 0.24;
      cells.push(
        <span
          key={`${x}-${y}`}
          className="place-self-center rounded-full bg-[#b5c96a]"
          style={{
            width: `${size}em`,
            height: `${size}em`,
            opacity: 0.25 + lit * 0.75,
          }}
        />,
      );
    }
  }
  return (
    <span
      aria-hidden
      className="grid"
      style={{
        gridTemplateColumns: `repeat(${COLUMNS}, 0.66em)`,
        gridAutoRows: "0.66em",
      }}
    >
      {cells}
    </span>
  );
}

/* ------------------------------------------------------------------- kimi --- */

// Kimi Code draws a blue-bordered welcome card with a key/value block, then a
// highlight line, its boxed composer, and a git-aware status line.
function KimiTui() {
  const ROWS = [
    ["Directory:", PATH],
    ["Session:", "session_723638cd-b2bf-4156"],
    ["Model:", "kimi-for-coding"],
    ["Version:", "0.23.4"],
  ] as const;
  return (
    <AgentWindow>
      <div className="flex h-full flex-col pt-[0.4em]">
        <div className="rounded-[0.35em] border border-[#3b6fd4] px-[1em] py-[0.8em]">
          <div className="flex items-center gap-[0.9em]">
            <span
              className="relative grid shrink-0 place-items-center rounded-[0.12em] bg-[#2d64d8]"
              style={{ width: "2.2em", height: "1.6em" }}
              aria-hidden
            >
              <span className="flex gap-[0.35em]">
                <span className="block h-[0.42em] w-[0.2em] bg-white" />
                <span className="block h-[0.42em] w-[0.2em] bg-white" />
              </span>
            </span>
            <div className="min-w-0">
              <p className="font-semibold text-[#5b8def]">
                Welcome to Kimi Code!
              </p>
              <p className="truncate text-white/40">
                Run <span className="text-white/60">/login</span> to get started.
              </p>
            </div>
          </div>
          <div className="mt-[0.7em] space-y-[0.05em]">
            {ROWS.map(([key, value]) => (
              <p key={key} className="flex gap-[0.6em] truncate">
                <span className="w-[5.6em] shrink-0 text-white/40">{key}</span>
                <span className="truncate text-white/80">{value}</span>
              </p>
            ))}
          </div>
        </div>
        <p className="mt-[0.9em] text-white/85">Select platform</p>
        <div className="mt-[0.4em]">
          <p className="truncate">
            <span className="text-[#5b8def]">❯ </span>
            <span className="text-white">1. Moonshot</span>{" "}
            <span className="text-white/35">kimi-for-coding</span>
          </p>
          <p className="truncate text-white/60">
            <span className="text-transparent">❯ </span>2. [ Add New Platform ]
          </p>
        </div>

        <div className="mt-auto">
          <BoxedInput char=">" />
          <p className="mt-[0.5em] flex gap-[0.7em] truncate text-[0.9em] text-white/35">
            <span className="shrink-0 text-white/55">K2.7 Coding</span>
            <span className="truncate">…/GitHub/fyolo main [+1060 -401]</span>
          </p>
          <p className="truncate text-right text-[0.9em] text-white/30">
            context: 0.0% (0/262.1k)
          </p>
        </div>
      </div>
    </AgentWindow>
  );
}

/* --------------------------------------------------------------------- pi --- */

// Pi prints a dense startup block — key bindings, then the skills and
// extensions it loaded — over a purple-ruled composer and a cost/model line.
function PiTui() {
  return (
    <AgentWindow>
      <div className="flex h-full flex-col pt-[0.5em]">
        <p>
          <span className="font-semibold text-[#5fc9c3]">pi</span>{" "}
          <span className="text-white/40">v0.80.6</span>
        </p>
        <p className="text-white/40">
          escape interrupt · ctrl+c/ctrl+d clear/exit · / commands · ! bash
        </p>
        <p className="mt-[0.7em] text-white/55">
          Pi can explain its own features and look up its docs.
        </p>
        <p className="mt-[0.7em] text-[#e0a458]">[Skills]</p>
        <p className="truncate pl-[0.8em] text-white/60">
          get-design-md, pdf, prompt-coach
        </p>
        <p className="mt-[0.5em] text-[#e0a458]">[Extensions]</p>
        <p className="truncate pl-[0.8em] text-white/60">
          pi-agent, muxy-notify.ts, pi-kimi-coder
        </p>
        <div className="mt-auto">
          <RuledInput char="" rule="rgba(150,130,220,0.5)" />
          <p className="mt-[0.4em] truncate text-[0.92em] text-white/45">
            {PATH} (main)
          </p>
          <p className="flex gap-[0.8em] truncate text-[0.92em] text-white/35">
            <span>↑8.3k ↓13 $0.042 (sub) 3.1%/272k</span>
            <span className="ml-auto shrink-0 truncate">
              (openai-codex) gpt-5.5 · high
            </span>
          </p>
        </div>
      </div>
    </AgentWindow>
  );
}

/* ------------------------------------------------------------------ crush --- */

// Crush opens on Charm's hatched banner over a block wordmark, then the model
// line and the three-column inventory of what it loaded for this repo — LSPs,
// MCP servers, skills — above its composer and key hints.
function CrushTui() {
  // This repo's own skills, which is what Crush picks up from `skills/` here.
  const SKILLS = [
    "animation-vocabulary",
    "app-screenshot-debug",
    "apple-design",
    "asc",
    "bump-version",
    "check-ghostty-update",
    "conventional-commit",
    "dia-source-analysis",
  ];
  return (
    <AgentWindow>
      <div className="flex h-full flex-col pt-[0.3em]">
        <CrushBanner />
        <p className="mt-[0.9em] truncate text-white/50">{PATH}</p>
        <p className="mt-[0.9em] truncate">
          <span className="text-white/35">◇ </span>
          <span className="text-white/90">Claude Opus 5</span>{" "}
          <span className="text-white/50">via AWS Bedrock US</span>
        </p>
        <p className="pl-[1.2em] text-white/35">Reasoning High</p>
        {/* Crush gives the three columns equal thirds; the skill names are the
            only ones long enough to care, so they get the slack. */}
        <div className="mt-[1em] grid grid-cols-[1fr_1fr_1.45fr] gap-[0.6em]">
          <p className="text-white/35">LSPs</p>
          <p className="text-white/35">MCPs</p>
          <p className="text-white/35">Skills</p>
        </div>
        <div className="mt-[0.9em] grid grid-cols-[1fr_1fr_1.45fr] gap-[0.6em]">
          <p className="text-white/35">None</p>
          <p className="text-white/35">None</p>
          <div className="min-w-0">
            {SKILLS.map((skill) => (
              <p key={skill} className="truncate">
                <span className="text-[#12c78f]">● </span>
                <span className="text-white/50">{skill}</span>
              </p>
            ))}
          </div>
        </div>
        <div className="mt-auto pt-[0.8em]">
          <p className="truncate">
            <span className="text-[#68ffd6]">&gt; </span>
            <span className="text-white/35">Ready for instructions</span>
          </p>
          <p className="text-[#12c78f]">:::</p>
          <p className="text-[#12c78f]">:::</p>
          <p className="mt-[0.8em] truncate text-[0.92em]">
            <span className="text-white/50">/ or ctrl+p</span>{" "}
            <span className="text-white/35">commands</span>{" "}
            <span className="text-white/20">•</span>{" "}
            <span className="text-white/50">ctrl+m</span>{" "}
            <span className="text-white/35">models</span>{" "}
            <span className="text-white/20">•</span>{" "}
            <span className="text-white/50">shift+enter</span>{" "}
            <span className="text-white/35">newline</span>
          </p>
        </div>
      </div>
    </AgentWindow>
  );
}

// The banner is three columns that share four rows: a fixed hatch block, the
// wordmark, and a hatch fill that runs off the right edge. Crush stretches one
// letter of the wordmark to whatever width it is given; these are the letter
// forms at their natural five cells.
const CRUSH_WORDMARK = [
  "▄▀▀▀▀ █▀▀▀▄ █   █ ▄▀▀▀▀ █   █",
  "█     █▀▀▀▄ █   █ ▀▀▀▀█ █▀▀▀█",
  " ▀▀▀▀ ▀   ▀  ▀▀▀  ▀▀▀▀  ▀   ▀",
];

function CrushBanner() {
  const hatch = "╱".repeat(6);
  const fill = "╱".repeat(48);
  return (
    <div className="flex gap-[0.6em] overflow-hidden" style={{ lineHeight: 1 }}>
      <div className="shrink-0 text-[#6b50ff]">
        {[0, 1, 2, 3].map((row) => (
          <p key={row} style={{ height: "1.02em" }}>
            {hatch}
          </p>
        ))}
      </div>
      <div className="shrink-0">
        <p
          className="flex justify-between gap-[1.5em]"
          style={{ height: "1.02em" }}
        >
          <span className="text-[#ff60ff]">Charm™</span>
          <span className="text-[#6b50ff]">v0.89.0</span>
        </p>
        {/* One gradient across the whole wordmark, clipped to the glyphs, the
            way Crush ramps magenta to violet from the C to the H. */}
        <CharGrid
          lines={CRUSH_WORDMARK}
          className="bg-gradient-to-r from-[#ff60ff] to-[#6b50ff] bg-clip-text text-transparent"
        />
      </div>
      <div className="min-w-0 flex-1 overflow-hidden text-[#6b50ff]">
        {[0, 1, 2, 3].map((row) => (
          <p
            key={row}
            className="whitespace-nowrap"
            style={{ height: "1.02em" }}
          >
            {fill}
          </p>
        ))}
      </div>
    </div>
  );
}

/* ------------------------------------------------------------------- grok --- */

// Grok's launch screen: the branch and directory it opened in, its braille
// mark, the four things it can do before a prompt, a rotating tip, and a boxed
// composer carrying the model and approval mode on its lower border.
const GROK_MARK = [
  "⠀⠀⠀⠀⠀⠀⣀⣀⡀⠀⠀⠀⢀⠄",
  "⠀⠀⠀⣠⣾⠿⠛⠛⠛⠛⢀⡴⠁⠀",
  "⠀⠀⣼⡟⠁⠀⠀⠀⢀⡴⠻⣿⡀⠀",
  "⠀⠀⣿⡇⠀⠀⠀⠔⠁⠀⠀⣿⡇⠀",
  "⠀⠀⢹⣷⠀⠀⠀⠀⠀⢀⣴⡿⠀⠀",
  "⠀⢀⠞⠁⠠⢶⣶⣶⣶⠿⠋⠀⠀⠀",
  "⠐⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀",
];

const GROK_MENU = [
  ["New worktree", "ctrl+w"],
  ["Resume session", "ctrl+s"],
  ["Changelog", ""],
  ["Quit", "ctrl+q"],
] as const;

function GrokTui() {
  return (
    <AgentWindow>
      <div className="flex h-full flex-col pt-[0.4em]">
        <p className="flex gap-[1.2em] truncate">
          <span className="shrink-0 text-white/85">main</span>
          <span className="truncate text-white/35">{PATH}</span>
        </p>
        <div className="mt-[1.2em] flex justify-center text-white/45">
          <CharGrid lines={GROK_MARK} cell={0.74} />
        </div>
        <div className="mt-[1.4em] px-[1.4em]">
          {GROK_MENU.map(([label, key]) => (
            <p key={label} className="flex gap-[1em] truncate">
              <span className="truncate text-white/85">{label}</span>
              <span className="ml-auto shrink-0 text-white/40">{key}</span>
            </p>
          ))}
        </div>
        {/* Grok leaves the middle of the screen empty and stacks the tip on
            top of the composer, so the whole block hangs off the bottom. */}
        <div className="mt-auto">
          <p className="text-pretty text-white/40">
            <span className="font-semibold">Tip:</span> Run{" "}
            <span className="text-white/70">/compact [context]</span> when chat
            gets long.
          </p>
          <div className="relative mt-[1.4em]">
            <BoxedInput char="❯" />
            <span className="absolute -bottom-[0.75em] right-[0.9em] max-w-[90%] truncate bg-[#1c1c1e] px-[0.4em] text-[0.92em] text-white/45">
              Grok 4.6 (high){" "}
              <span className="text-white/30">·</span> always-approve
            </span>
          </div>
          <p className="mt-[1.6em] truncate text-right">
            <span className="text-white/70">Grok Build</span>{" "}
            <span className="text-white/35">1.0.5 [stable]</span>
          </p>
        </div>
      </div>
    </AgentWindow>
  );
}

/* ------------------------------------------------------------------------ */

const BY_AGENT: Record<string, () => React.ReactElement> = {
  "Claude Code": ClaudeTui,
  Codex: CodexTui,
  OpenCode: OpenCodeTui,
  Amp: AmpTui,
  Kimi: KimiTui,
  Pi: PiTui,
  Crush: CrushTui,
  Grok: GrokTui,
};

export function AgentTui({ name }: { name: string }) {
  const Tui = BY_AGENT[name];
  return Tui ? <Tui /> : null;
}
