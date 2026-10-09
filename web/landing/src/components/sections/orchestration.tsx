import { Reveal } from "@/components/reveal";
import { OrchestrationDemo } from "@/components/sections/orchestration-demo";

// The orchestration API — the machinery behind the hero's "orchestrate your
// fleet" claim. Copy and the terminal transcript mirror the real CLI surface
// (scripts/fyolo + /docs/session-control); nothing here is aspirational.
//
// Layout: one bg-card article holding heading, demo, and closing line — the same
// single-surface shape as the agent showcase, so adjacent sections match.
export function Orchestration() {
  return (
    <section id="orchestration" className="scroll-mt-24">
      <div className="mx-auto w-full max-w-6xl px-5 pb-32 pt-8 sm:px-8 sm:pb-40 sm:pt-10">
        <Reveal as="article" className="rounded-3xl bg-card p-6 sm:p-10 lg:p-14">
          <div className="flex flex-col items-center text-center">
            <h2 className="text-balance text-3xl font-medium leading-[1.1] tracking-tight text-foreground sm:text-[44px]">
              Agents driving agents
            </h2>
            <p className="mt-5 max-w-lg text-balance text-base leading-relaxed text-muted-foreground">
              The <code className="font-mono text-[0.92em]">fyolo sessions</code>{" "}
              CLI turns the fleet into an API: any agent — or your own scripts —
              can start siblings, answer their prompts, and supervise the whole
              project without touching a GUI.
            </p>
          </div>

          <div className="mt-12 w-full">
            <OrchestrationDemo />
          </div>

          <p className="mt-12 text-balance text-center text-sm text-muted-foreground">
            Your agents get the same commands you do: spawn a session, answer
            its prompt, read its reply.
          </p>
        </Reveal>
      </div>
    </section>
  );
}
