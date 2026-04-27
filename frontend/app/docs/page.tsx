import fs from "node:fs/promises";
import path from "node:path";
import Link from "next/link";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import rehypeKatex from "rehype-katex";
import type { Components } from "react-markdown";

type DocsPageProps = {
  searchParams?: {
    view?: string;
  };
};

const DOC_VIEW = "docs";
const WHITEPAPER_VIEW = "whitepaper";

const markdownComponents: Components = {
  h1: ({ children }) => (
    <h1 className="mt-8 mb-4 text-3xl font-black tracking-tight text-neutral-900 sm:text-4xl">{children}</h1>
  ),
  h2: ({ children }) => (
    <h2 className="mt-8 mb-3 text-2xl font-black tracking-tight text-neutral-900 sm:text-3xl">{children}</h2>
  ),
  h3: ({ children }) => <h3 className="mt-6 mb-3 text-xl font-bold text-neutral-900">{children}</h3>,
  p: ({ children }) => <p className="my-4 leading-8 text-neutral-800">{children}</p>,
  ul: ({ children }) => <ul className="my-4 list-disc space-y-2 pl-6 text-neutral-800">{children}</ul>,
  ol: ({ children }) => <ol className="my-4 list-decimal space-y-2 pl-6 text-neutral-800">{children}</ol>,
  li: ({ children }) => <li className="leading-7">{children}</li>,
  blockquote: ({ children }) => (
    <blockquote className="my-6 border-l-4 border-neutral-900 bg-neutral-50 px-4 py-2 italic text-neutral-700">
      {children}
    </blockquote>
  ),
  a: ({ href, children }) => (
    <a href={href} className="font-semibold text-neutral-900 decoration-2 underline-offset-4" target="_blank" rel="noreferrer">
      {children}
    </a>
  ),
  hr: () => <hr className="my-8 border-0 border-t-2 border-neutral-200" />,
  table: ({ children }) => (
    <div className="my-6 overflow-x-auto">
      <table className="min-w-full border-collapse border-2 border-neutral-900 text-left text-sm">{children}</table>
    </div>
  ),
  thead: ({ children }) => <thead className="bg-neutral-100">{children}</thead>,
  th: ({ children }) => <th className="border border-neutral-900 px-3 py-2 font-bold text-neutral-900">{children}</th>,
  td: ({ children }) => <td className="border border-neutral-300 px-3 py-2 align-top text-neutral-800">{children}</td>,
  pre: ({ children }) => (
    <pre className="my-6 overflow-x-auto rounded-xl border-2 border-neutral-900 bg-neutral-950 p-4 text-sm text-neutral-100">
      {children}
    </pre>
  ),
  code: ({ children, className }) => {
    const content = String(children).replace(/\n$/, "");
    const isBlock = Boolean(className?.includes("language-")) || content.includes("\n");

    if (isBlock) {
      return <code className={`${className ?? ""} font-mono leading-7`}>{content}</code>;
    }

    return (
      <code className="rounded-md border border-neutral-300 bg-neutral-100 px-1.5 py-0.5 font-mono text-[0.9em] text-neutral-900">
        {content}
      </code>
    );
  },
};

async function readMarkdownFile(relativePath: string): Promise<string> {
  const absolutePath = path.resolve(process.cwd(), "..", relativePath);
  try {
    return await fs.readFile(absolutePath, "utf8");
  } catch {
    return `Unable to load \`${relativePath}\` from the workspace.`;
  }
}

function tabClass(isActive: boolean): string {
  if (isActive) {
    return "rounded-full border-2 border-neutral-900 bg-[#d4ff00] px-5 py-2 text-xs font-bold uppercase tracking-widest text-neutral-900 shadow-[3px_3px_0px_#000]";
  }

  return "rounded-full border-2 border-neutral-900 bg-white px-5 py-2 text-xs font-bold uppercase tracking-widest text-neutral-900 shadow-[3px_3px_0px_#000] hover:bg-[#d4ff00]";
}

export default async function DocsPage({ searchParams }: DocsPageProps) {
  const selectedView = searchParams?.view === WHITEPAPER_VIEW ? WHITEPAPER_VIEW : DOC_VIEW;

  const docsContentPromise = readMarkdownFile("docs/README.md");
  const whitepaperContentPromise = readMarkdownFile("docs/WHITEPAPER.md");

  const [docsContent, whitepaperContent] = await Promise.all([
    docsContentPromise,
    whitepaperContentPromise,
  ]);

  const content = selectedView === WHITEPAPER_VIEW ? whitepaperContent : docsContent;
  const title = selectedView === WHITEPAPER_VIEW ? "Whitepaper" : "Documentation";
  const sourcePath = selectedView === WHITEPAPER_VIEW ? "docs/WHITEPAPER.md" : "docs/README.md";

  return (
    <main className="mx-auto min-h-screen w-full max-w-6xl px-6 py-12 md:py-16">
      <header className="mb-8">
        <h1 className="text-4xl font-black tracking-tight text-neutral-900 sm:text-5xl">Project Docs</h1>
        <p className="mt-4 max-w-3xl text-base font-medium text-neutral-700 sm:text-lg">
          View CreditLayer documentation and the protocol whitepaper directly in the app.
        </p>
      </header>

      <section className="mb-6 flex flex-wrap items-center gap-3">
        <Link href="/docs?view=docs" className={tabClass(selectedView === DOC_VIEW)}>
          Docs
        </Link>
        <Link href="/docs?view=whitepaper" className={tabClass(selectedView === WHITEPAPER_VIEW)}>
          Whitepaper
        </Link>
      </section>

      <section className="rounded-2xl border-2 border-neutral-900 bg-white shadow-[6px_6px_0px_#000]">
        <div className="flex flex-wrap items-center justify-between gap-2 border-b-2 border-neutral-900 px-5 py-4">
          <h2 className="text-lg font-bold uppercase tracking-wide text-neutral-900">{title}</h2>
          <span className="rounded-md border border-neutral-300 bg-neutral-50 px-2 py-1 text-xs font-semibold text-neutral-700">
            Source: {sourcePath}
          </span>
        </div>

        <div className="max-h-[70vh] overflow-auto p-5">
          <article className="docs-markdown">
            <ReactMarkdown
              components={markdownComponents}
              remarkPlugins={[remarkGfm, remarkMath]}
              rehypePlugins={[rehypeKatex]}
            >
              {content}
            </ReactMarkdown>
          </article>
        </div>
      </section>
    </main>
  );
}
