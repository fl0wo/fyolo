import Link from "next/link";
import { cn } from "@/lib/utils";
import { Logo } from "@/components/logo";
import { AppleMark, GitHubMark } from "@/components/section-label";
import { downloadUrl, githubUrl } from "@/lib/site";

// Superwhisper's nav: a single centered floating pill holding GitHub + a white
// Download button, with the wordmark parked on the far left.
export function SiteNav() {
  return (
    <header className="fixed inset-x-0 top-0 z-50 pt-4">
      <div className="relative mx-auto flex w-full max-w-6xl items-center justify-center px-5 sm:px-8">
        <Link
          href="/"
          className="group absolute left-5 hidden rounded-md focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-ring sm:left-8 sm:block"
          aria-label="Fyolo home"
        >
          <Logo size="lg" />
        </Link>

        <nav
          aria-label="Primary"
          className="liquid-glass flex items-center gap-1 rounded-full p-1.5"
        >
          <a
            href={githubUrl}
            target="_blank"
            rel="noreferrer"
            aria-label="Fyolo on GitHub"
            className="inline-flex items-center gap-1.5 rounded-full px-3 py-1.5 text-sm font-medium text-foreground transition-all duration-200 ease-[var(--ease-apple)] hover:bg-foreground/[0.08] hover:shadow-[inset_0_0_0_1px_rgba(255,255,255,0.08)] sm:px-4"
          >
            <GitHubMark className="h-4 w-4" />
            <span>GitHub</span>
          </a>
          <a
            href={downloadUrl}
            className={cn(
              "ml-1 inline-flex items-center gap-1.5 rounded-full bg-primary px-3.5 py-1.5 text-sm font-semibold text-primary-foreground transition-all duration-200 ease-[var(--ease-apple)] hover:brightness-110 active:scale-[0.98] sm:px-4",
            )}
          >
            <AppleMark className="h-3.5 w-3.5" />
            Download
          </a>
        </nav>
      </div>
    </header>
  );
}
