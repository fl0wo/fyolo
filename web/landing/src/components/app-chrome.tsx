import { cn } from "@/lib/utils";

// The pieces of Fyolo's own chrome, drawn in DOM so the marketing mocks stay
// crisp at any size and can animate. Shared by the orchestration demo and the
// feature grid's mocks, so a detail only has to be right once.
//
// Everything here is ported from the app rather than invented: the status
// language from Sidebar/SidebarView.swift, the working mark's geometry from
// Shared/FyoloShared/SessionStatus.swift.

export type Status = "idle" | "working" | "needs-you" | "done";

// Green done / orange needs-you is the sidebar's only color channel — the app
// deliberately keeps per-agent brand tints out of it, so the mocks do too.
export const DONE = "#27c93f"; // brand-green — matches StatusRing's .green
export const NEEDS_YOU = "#ffb764"; // brand-amber — matches StatusRing's .orange

export function TrafficLights({ size = 11 }: { size?: number }) {
  return (
    <div
      className="flex shrink-0 items-center"
      style={{ gap: Math.round(size * 0.55) }}
    >
      {["bg-brand-red", "bg-brand-amber", "bg-brand-green"].map((tone) => (
        <span
          key={tone}
          className={cn("rounded-full", tone)}
          style={{ width: size, height: size }}
        />
      ))}
    </div>
  );
}

// The resting "your turn" status, drawn as a ring *around* a session's leading
// mark — green when the agent just finished, orange when it is blocked on you.
// Working is the spinner and idle is nothing, so only those two light the ring.
// An overlay, so it never shifts the row it sits in.
export function StatusRing({
  status,
  size = 20,
}: {
  status: Status;
  size?: number;
}) {
  return (
    <span
      className="pointer-events-none absolute rounded-full border-[1.5px] transition-colors duration-300"
      style={{
        width: size,
        height: size,
        borderColor:
          status === "done"
            ? DONE
            : status === "needs-you"
              ? NEEDS_YOU
              : "transparent",
      }}
    />
  );
}

// The eight perimeter cells of a 3×3 grid in clockwise order, as (column, row)
// with the center at (1,1) — the ring the comet travels.
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
const PERIOD = 1.1; // seconds a lap, as in the Swift original

// The app's "agent is working" mark: a comet runs the eight perimeter cells of
// a 3×3 dot grid over a steady half-ink center. Geometry scales off `size` from
// the app's 13pt/2.5pt/3.6pt trio; the brightness and swell ramps live in the
// `working-comet` keyframes, and each dot's place on the ring is a negative
// animation delay.
export function WorkingIndicator({ size = 13 }: { size?: number }) {
  const dot = (size / 13) * 2.5;
  const pitch = (size / 13) * 3.6;
  return (
    <span
      className="relative block shrink-0 text-foreground"
      style={{ width: size, height: size }}
    >
      {[[1, 1] as const, ...RING].map(([column, row], i) => (
        <span
          key={`${column}-${row}`}
          className={cn(
            "absolute rounded-full bg-current",
            // The center dot is the steady anchor; only the ring animates.
            i === 0 ? "opacity-50" : "working-dot",
          )}
          style={{
            width: dot,
            height: dot,
            left: `calc(50% + ${(column - 1) * pitch - dot / 2}px)`,
            top: `calc(50% + ${(row - 1) * pitch - dot / 2}px)`,
            animationDelay: i === 0 ? undefined : `${-((i - 1) / 8) * PERIOD}s`,
          }}
        />
      ))}
    </span>
  );
}

export function FolderGlyph({ className }: { className?: string }) {
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

export function BranchGlyph({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={2}
      strokeLinecap="round"
      className={cn("shrink-0", className)}
    >
      <line x1="6" y1="3" x2="6" y2="15" />
      <circle cx="18" cy="6" r="3" />
      <circle cx="6" cy="18" r="3" />
      <path d="M18 9a9 9 0 0 1-9 9" />
    </svg>
  );
}

// Settings ▸ SSH gives a remote host this glyph, and so does a session running
// on one — a globe would read as "web", not "that box".
export function ServerGlyph({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.7}
      strokeLinejoin="round"
      className={cn("shrink-0", className)}
    >
      <rect x="3" y="4" width="18" height="7" rx="2" />
      <rect x="3" y="13" width="18" height="7" rx="2" />
      <path d="M7 7.5h.01M7 16.5h.01" />
    </svg>
  );
}

// The window a mock lives in: the app's rounded frame, with the sidebar tone a
// step above the terminal's near-black and the inset top hairline plus cast
// shadow that make it read as a real macOS window rather than a flat panel.
export function MockWindow({
  className,
  children,
}: {
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <div
      aria-hidden="true"
      className={cn(
        "flex overflow-hidden rounded-xl border border-white/10 bg-[#1b1b21]",
        "shadow-[inset_0_1px_0_0_rgba(255,255,255,0.07),0_16px_32px_-18px_rgba(0,0,0,0.8)]",
        className,
      )}
    >
      {children}
    </div>
  );
}
