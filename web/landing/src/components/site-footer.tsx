import { githubUrl } from "@/lib/site";

const footerLinks: { label: string; href: string }[] = [
  { label: "GitHub", href: githubUrl },
  { label: "Privacy", href: "/privacy" },
  { label: "Terms", href: "/terms" },
];

// Glaze-style footer, kept to a single centered row on wide screens: copyright,
// page links, and the tagline. No border, no link grid; on the homepage it
// floats over the outro aurora, on inner pages it just sits on the canvas.
export function SiteFooter() {
  return (
    <footer className="px-5 py-6 sm:px-8 sm:py-8">
      <div className="mx-auto flex w-full max-w-[960px] flex-col items-center justify-center gap-2 text-sm leading-5 text-muted-foreground sm:flex-row sm:gap-4">
        <span>© {new Date().getFullYear()} Fyolo</span>
        <nav
          className="flex items-center justify-center gap-4"
          aria-label="Footer"
        >
          {footerLinks.map((link) => (
            <a
              key={link.label}
              href={link.href}
              className="py-1 text-muted-foreground transition-colors hover:text-foreground"
            >
              {link.label}
            </a>
          ))}
        </nav>
        <span className="font-mono text-xs text-muted-foreground/80">
          Built for AI Builders by AI Builders.
        </span>
      </div>
    </footer>
  );
}
