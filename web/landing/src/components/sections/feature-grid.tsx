import { Reveal } from "@/components/reveal";
import { SectionLabel } from "@/components/section-label";
import {
  InspectorMock,
  MarkdownMock,
  PaletteMock,
  RemoteMock,
  SidebarMock,
  WorktreeMock,
} from "@/components/sections/feature-mocks";

// Six cards, each carrying a small animated mock of the surface it describes
// (see feature-mocks.tsx) rather than a screenshot — the same DOM-drawn app
// chrome the orchestration demo uses, so the whole page reads as one product
// rather than a page about one.
const features = [
  {
    title: "A fleet you can read",
    blurb:
      "Every session reports a live status — working, finished, or blocked on you — and the same three states aggregate into the menu-bar tray.",
    Mock: SidebarMock,
  },
  {
    title: "Command palette",
    blurb:
      "⇧⌘P runs any action, and Open Quickly jumps to any session, project, or file. Themes preview live as you browse them — Enter keeps, Esc puts it back.",
    Mock: PaletteMock,
  },
  {
    title: "Files beside the terminal",
    blurb:
      "Browse the project, open files in a syntax-highlighted editor, read the git diff, search contents — a side panel that never pulls you out of the terminal.",
    Mock: InspectorMock,
  },
  {
    title: "Markdown you can actually read",
    blurb:
      "Open a README or a plan and Fyolo renders it — GFM tables, task lists, math, Mermaid diagrams — in your terminal theme, beside the agent writing it.",
    Mock: MarkdownMock,
  },
  {
    title: "Your other machines",
    blurb:
      "Fyolo runs sessions on the hosts in your own ~/.ssh/config, each wearing its machine's mark. System OpenSSH does the connecting — no embedded client, no relay.",
    Mock: RemoteMock,
  },
  {
    title: "A worktree per agent",
    blurb:
      "Worktrees are read straight from git and nested under the project, so two agents can work the same repo without ever touching each other's files.",
    Mock: WorktreeMock,
  },
] as const;

export function FeatureGrid() {
  return (
    <section id="features" className="scroll-mt-24">
      {/* Light top padding — the showcase above already ends with pb-32/40. */}
      <div className="mx-auto w-full max-w-6xl px-5 pb-32 pt-8 sm:px-8 sm:pb-40 sm:pt-10">
        <Reveal className="flex flex-col items-center text-center">
          <SectionLabel accent="muted">What&apos;s inside</SectionLabel>
          <h2 className="mt-4 text-balance text-3xl font-medium leading-[1.1] tracking-tight text-foreground sm:text-[44px]">
            Built for agentic coding
          </h2>
          <p className="mt-5 max-w-lg text-balance text-base leading-relaxed text-muted-foreground">
            Several agents going at once, most of them fine without you, one of
            them stuck — Fyolo keeps the whole fleet in view.
          </p>
        </Reveal>

        <div className="mt-12 grid gap-5 sm:grid-cols-2 sm:gap-6 lg:grid-cols-3">
          {features.map((feature, i) => (
            <Reveal
              key={feature.title}
              as="article"
              delayMs={(i % 3) * 80}
              className="flex flex-col rounded-3xl bg-card p-6"
            >
              <h3 className="text-lg font-medium tracking-tight text-foreground">
                {feature.title}
              </h3>
              <p className="mt-2 text-pretty text-sm leading-relaxed text-muted-foreground">
                {feature.blurb}
              </p>
              <div className="mt-auto pt-6">
                <feature.Mock />
              </div>
            </Reveal>
          ))}
        </div>

        <Reveal delayMs={80}>
          <p className="mx-auto mt-10 max-w-3xl text-balance text-center text-sm leading-relaxed text-muted-foreground">
            Also in the box: your Claude and Codex plan limits read from your own
            credentials, hundreds of terminal themes with light, dark, and glass
            window looks, and Ghostty-style split panes.
          </p>
        </Reveal>
      </div>
    </section>
  );
}
