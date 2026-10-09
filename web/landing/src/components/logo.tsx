import Image from "next/image";
import { cn } from "@/lib/utils";

// The Fyolo wordmark: the real macOS app icon set next to the name.
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
      <Image
        src="/logo.png"
        alt=""
        aria-hidden="true"
        width={40}
        height={40}
        className={cn(lg ? "h-9 w-9" : "h-7 w-7")}
        priority
      />
      <span
        className={cn(
          "font-semibold tracking-tight text-foreground transition-colors group-hover:text-foreground/80",
          lg ? "text-xl" : "text-lg",
        )}
      >
        Fyolo
      </span>
    </span>
  );
}
