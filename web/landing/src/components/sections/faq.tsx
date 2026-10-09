import {
  Accordion,
  AccordionItem,
  AccordionTrigger,
  AccordionContent,
} from "@/components/ui/accordion";
import { Reveal } from "@/components/reveal";
import { SectionLabel } from "@/components/section-label";
import { supportedAgents } from "@/lib/site";

// Plain strings (not JSX) so the same copy feeds both the rendered accordion
// and the FAQPage structured data below.
const faqs: { question: string; answer: string }[] = [
  {
    question: "Is Fyolo free?",
    answer: "Yes. Fyolo is free and open source. No account, no cloud.",
  },
  {
    question:
      "What happens to a running agent when I quit Fyolo or close the laptop?",
    answer:
      "Sessions are hosted by fyolod, not the app window. Quit Fyolo, sleep the laptop, or reboot — the agent keeps running. Reattach restores the exact screen.",
  },
  {
    question: "Can I run agents on a remote machine?",
    answer:
      "Yes. Any Linux VPS you can ssh to — Fyolo reads ~/.ssh/config and never rewrites it. Set Up copies one binary over SSH, starts the daemon, and installs the agents’ hooks there. Local and remote sessions run through the same host.",
  },
  {
    question: "How is this different from Zed remote or VS Code Remote?",
    answer:
      "The session lives on the machine, not in the connection. Drop the link and the agent keeps running; reattach restores the exact screen. Zed Remote and VS Code Remote keep remote work inside a live connection.",
  },
  {
    question: "How is this different from tmux?",
    answer:
      "tmux is a prefix-key multiplexer you attach a terminal to. Fyolo is a native Mac app with its own session host — same sessions on this Mac, a remote box, or the iPhone companion. You don’t have to learn tmux. There is no prefix key to remember.",
  },
  {
    question: "Which agents are supported?",
    answer: `${supportedAgents.join(", ")}, and any other coding agent that runs in a terminal. Each session is a real terminal, not a chat view.`,
  },
  {
    question: "How does Fyolo know when an agent needs me?",
    answer:
      "Agents report working, needs you and done through hooks Fyolo installs. If a hook isn’t there, Fyolo reads the screen.",
  },
  {
    question: "Is my code private?",
    answer:
      "Yes. No account, no cloud, no telemetry. Code never leaves machines you own.",
  },
  {
    question: "Is Fyolo a fork of Ghostty?",
    answer: "No. Fyolo is built on libghostty. It is not a fork.",
  },
  {
    question: "Is there an iPhone app?",
    answer:
      "Yes. A free iPhone companion mirrors sessions live; it’s in TestFlight beta. Remote access uses a tunnel you choose — Tunelo, Cloudflare, ngrok, or a self-hosted relay.",
  },
  {
    question: "Can I script it?",
    answer:
      "Yes. The fyolo CLI drives the running app over a local socket, and ships as an agent skill.",
  },
  {
    question: "What are the requirements?",
    answer:
      "macOS 14 or later. Universal binary, so the same download runs on Apple silicon and Intel. You bring the agent CLIs and their credentials.",
  },
];

// FAQPage structured data so the questions are eligible for rich results.
const faqJsonLd = {
  "@context": "https://schema.org",
  "@type": "FAQPage",
  mainEntity: faqs.map((faq) => ({
    "@type": "Question",
    name: faq.question,
    acceptedAnswer: { "@type": "Answer", text: faq.answer },
  })),
};

export function Faq() {
  return (
    <section id="faq" className="scroll-mt-24">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(faqJsonLd) }}
      />
      {/* Light top padding — the section above already ends with pb-32/40, so a
          full py-32 here would double the gap. */}
      <div className="mx-auto w-full max-w-2xl px-5 pb-32 pt-8 sm:pb-40 sm:pt-10 sm:px-8">
        <Reveal className="flex flex-col items-center text-center">
          <SectionLabel accent="muted">Support</SectionLabel>
          <h2 className="mt-4 text-balance text-3xl font-medium leading-[1.1] tracking-tight text-foreground sm:text-[44px]">
            Frequently asked questions
          </h2>
          <p className="mt-5 max-w-md text-balance text-base leading-relaxed text-muted-foreground">
            Can&apos;t find the answer you&apos;re looking for? The docs go
            deeper, or reach out and a human will help.
          </p>
        </Reveal>

        <Reveal delayMs={80} className="mt-10">
          <Accordion className="border-t border-border">
            {faqs.map((faq) => (
              <AccordionItem key={faq.question} value={faq.question}>
                <AccordionTrigger className="items-center py-5 text-base font-medium">
                  {faq.question}
                </AccordionTrigger>
                <AccordionContent className="pr-8 text-muted-foreground">
                  <p>{faq.answer}</p>
                </AccordionContent>
              </AccordionItem>
            ))}
          </Accordion>
        </Reveal>
      </div>
    </section>
  );
}
