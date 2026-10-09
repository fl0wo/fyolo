"use client";

import { useState } from "react";
import { HugeiconsIcon } from "@hugeicons/react";
import { Copy01Icon, Tick02Icon } from "@hugeicons/core-free-icons";
import { cn } from "@/lib/utils";

// "Copy for LLM" — copies the page's raw Markdown to the clipboard, so you can
// paste it into an agent for context. Borrowed from Warp's docs, and especially
// fitting here: Fyolo's readers are running coding agents all day.
export function CopyMarkdownButton({
  markdown,
  labels,
}: {
  markdown: string;
  labels: { copy: string; copied: string; aria: string };
}) {
  const [copied, setCopied] = useState(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(markdown);
      setCopied(true);
      setTimeout(() => setCopied(false), 1600);
    } catch {
      // Clipboard blocked (e.g. insecure context) — nothing useful to do.
    }
  }

  return (
    <button
      type="button"
      onClick={copy}
      aria-label={labels.aria}
      className={cn(
        "docs-page-action",
        copied ? "text-fd-foreground" : "text-fd-muted-foreground",
      )}
    >
      <HugeiconsIcon
        icon={copied ? Tick02Icon : Copy01Icon}
        size={16}
        aria-hidden="true"
      />
      {copied ? labels.copied : labels.copy}
    </button>
  );
}
