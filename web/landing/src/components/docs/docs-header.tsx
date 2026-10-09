import Link from "next/link";
import { FullSearchTrigger } from "fumadocs-ui/layouts/shared/slots/search-trigger";
import { Logo } from "@/components/logo";
import { GitHubMark } from "@/components/section-label";
import { ThemeSwitch } from "@/components/docs/theme-switch";
import { source } from "@/lib/source";
import { docsChrome } from "@/lib/docs-ui";
import type { DocsLanguage } from "@/lib/i18n";
import { githubUrl, downloadUrl } from "@/lib/site";

// The docs get their own top bar rather than the landing's floating pill. The
// pill is marketing chrome — it floats over a hero and pulls the eye; docs chrome
// should sit still, hold the reading column's edge, and carry the controls that
// only exist here (language, appearance). Same shape better-auth gives its docs:
// a fixed-height bar with a hairline under it, flush to the top of the page.
export function DocsHeader({ lang }: { lang: DocsLanguage }) {
  const chrome = docsChrome(lang);
  // The wordmark always goes to the site root: only the docs are translated, so
  // `/zh-CN` is not a page — it 404s. The locale lives on the Docs link below.
  const home = "/";
  const tree = source.getPageTree(lang);

  return (
    // Opaque, and no backdrop-filter. A translucent blurred header has to
    // re-sample the content moving underneath it on every frame, and that
    // re-rasterisation is what makes the sticky rails beside it shimmer while you
    // scroll. The landing's pill can afford the effect because it floats over a
    // hero; here there is nothing behind the bar worth seeing through it.
    <header className="sticky top-0 z-50 border-b border-border bg-background">
      {/* Equal outer columns keep search centred when either cluster changes width. */}
      <div className="docs-header-bar mx-auto grid h-14 w-full max-w-[97rem] items-center gap-3 px-5">
        <div className="flex items-center justify-self-start">
          <Link
            href={home}
            className="group flex shrink-0 items-center rounded-md focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-ring"
            aria-label="Fyolo"
          >
            <Logo />
          </Link>
        </div>
        <FullSearchTrigger
          aria-label={chrome.searchTrigger}
          className="docs-header-search"
        />
        <div className="flex items-center gap-2 justify-self-end">
          <ThemeSwitch chrome={chrome} />
          <span
            className="hidden h-5 w-px bg-border sm:block"
            aria-hidden="true"
          />
          <a
            href={githubUrl}
            target="_blank"
            rel="noreferrer"
            aria-label="Fyolo on GitHub"
            className="hidden h-7 w-7 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-secondary hover:text-foreground sm:inline-flex"
          >
            <GitHubMark className="h-4 w-4" />
          </a>
          <a
            href={downloadUrl}
            className="hidden h-7 items-center rounded-lg bg-primary px-3 text-[12px] font-semibold text-primary-foreground no-underline transition-all hover:brightness-110 active:scale-[0.98] md:inline-flex"
          >
            {chrome.download}
          </a>
        </div>
      </div>

      {/* The page tree, for the widths where the sidebar does not exist. A plain
          disclosure rather than a drawer: it needs no client JS, no context from
          the layout below, and it closes itself on navigation because the page
          reloads. Above `md` the sidebar carries this and the menu is hidden. */}
      <details className="group border-t border-border md:hidden">
        <summary className="flex cursor-pointer list-none items-center gap-2 px-5 py-2.5 text-[13px] text-muted-foreground [&::-webkit-details-marker]:hidden">
          <MenuIcon className="h-4 w-4" />
          {chrome.menu}
          <ChevronIcon className="ml-auto h-4 w-4 transition-transform group-open:rotate-180" />
        </summary>
        <nav className="border-t border-border px-3 pb-3 pt-1">
          {tree.children.map((node, index) => {
            if (node.type === "separator") {
              return (
                <p
                  key={`separator-${index}`}
                  className="px-2 pb-1 pt-3 text-[12px] font-semibold text-foreground"
                >
                  {node.name}
                </p>
              );
            }
            if (node.type !== "page") return null;
            return (
              <Link
                key={node.url}
                href={node.url}
                className="block px-2 py-1.5 text-[15px] text-muted-foreground no-underline transition-colors hover:text-foreground"
              >
                {node.name}
              </Link>
            );
          })}
        </nav>
      </details>
    </header>
  );
}

function ChevronIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" className={className}>
      <path d="m6 9 6 6 6-6" />
    </svg>
  );
}

function MenuIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden="true" className={className}>
      <path d="M4 7h16M4 12h16M4 17h16" />
    </svg>
  );
}
