import { cn } from "@/lib/utils";

// The mark: a solid purple F on a black square, the same drawing as the
// favicons (app/icon.png, app/apple-icon.png, app/favicon.ico). Its strokes sit
// on a 4-unit grid of the 64-unit box so they stay crisp at 16px; regenerate
// the favicons if it changes.
export function FyoloMark({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 64 64" aria-hidden="true" className={className}>
      <rect width="64" height="64" rx="12" fill="#000000" />
      <g fill="#741c92">
        <rect x="16" y="12" width="12" height="40" />
        <rect x="16" y="12" width="32" height="12" />
        <rect x="16" y="32" width="28" height="8" />
      </g>
    </svg>
  );
}

// The Fyolo wordmark: the mark set next to the name.
// Decorative — the surrounding link/anchor carries the accessible label.
export function Logo({
  className,
  size = "base",
}: {
  className?: string;
  size?: "base" | "lg";
}) {
  const lg = size === "lg";
  return (
    <span className={cn("inline-flex items-center gap-2.5", className)}>
      <FyoloMark className={cn(lg ? "h-9 w-9" : "h-7 w-7")} />
      <span
        className={cn(
          "font-semibold tracking-tight text-foreground transition-colors group-hover:text-foreground/80",
          lg ? "text-xl" : "text-lg",
        )}
      >
        fyolo
      </span>
    </span>
  );
}
