"use client";

import { useState } from "react";
import { HugeiconsIcon } from "@hugeicons/react";
import { Copy01Icon, Tick02Icon } from "@hugeicons/core-free-icons";
import { cn } from "@/lib/utils";
import { brewInstallCommand } from "@/lib/site";

// The hero's install line: the Homebrew cask the release workflow bumps, with a
// one-click copy so nobody retypes the tap name.
export function BrewInstall({ className }: { className?: string }) {
  const [copied, setCopied] = useState(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(brewInstallCommand);
      setCopied(true);
      setTimeout(() => setCopied(false), 1600);
    } catch {
      // Clipboard blocked (e.g. insecure context) — the command stays selectable.
    }
  }

  return (
    <div
      className={cn(
        "liquid-glass flex w-full max-w-xl items-center gap-3 rounded-2xl py-2 pl-5 pr-2 text-left",
        className,
      )}
    >
      <code className="min-w-0 flex-1 overflow-x-auto whitespace-nowrap py-2 font-mono text-[13px] text-foreground sm:text-[15px]">
        <span className="select-none text-muted-foreground">$ </span>
        {brewInstallCommand}
      </code>
      <button
        type="button"
        onClick={copy}
        aria-label={copied ? "Copied" : "Copy install command"}
        className="inline-flex h-9 shrink-0 items-center gap-1.5 rounded-xl px-3 text-sm font-medium text-muted-foreground transition-colors duration-200 hover:bg-foreground/[0.08] hover:text-foreground"
      >
        <HugeiconsIcon
          icon={copied ? Tick02Icon : Copy01Icon}
          size={16}
          aria-hidden="true"
        />
        <span className="hidden sm:inline">{copied ? "Copied" : "Copy"}</span>
      </button>
    </div>
  );
}
