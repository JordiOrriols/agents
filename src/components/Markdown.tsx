import React from "react";
import ReactMarkdown, { type Components } from "react-markdown";
import remarkGfm from "remark-gfm";

const components: Components = {
  h1: ({ children }) => <h2 className="mt-4 text-base font-semibold first:mt-0">{children}</h2>,
  h2: ({ children }) => <h3 className="mt-4 text-sm font-semibold first:mt-0">{children}</h3>,
  h3: ({ children }) => <h4 className="mt-3 text-sm font-medium first:mt-0">{children}</h4>,
  p: ({ children }) => <p className="mt-2 first:mt-0">{children}</p>,
  ul: ({ children }) => <ul className="mt-2 list-disc space-y-1 pl-5 first:mt-0">{children}</ul>,
  ol: ({ children }) => <ol className="mt-2 list-decimal space-y-1 pl-5 first:mt-0">{children}</ol>,
  a: ({ href, children }) => (
    <a href={href} target="_blank" rel="noreferrer" className="underline underline-offset-2">
      {children}
    </a>
  ),
  blockquote: ({ children }) => (
    <blockquote className="mt-2 border-l-2 border-border pl-3 text-muted-foreground first:mt-0">
      {children}
    </blockquote>
  ),
  table: ({ children }) => (
    <div className="mt-2 overflow-x-auto first:mt-0">
      <table className="w-full border-collapse text-left text-xs">{children}</table>
    </div>
  ),
  th: ({ children }) => <th className="border border-border px-2 py-1 font-medium">{children}</th>,
  td: ({ children }) => <td className="border border-border px-2 py-1 align-top">{children}</td>,
  pre: ({ children }) => (
    <pre className="mt-2 overflow-x-auto rounded bg-muted p-2 text-xs first:mt-0">{children}</pre>
  ),
  code: ({ children }) => <code className="font-mono text-[0.9em]">{children}</code>,
};

/** Agent reports. Raw HTML in them stays plain text, because they quote untrusted web pages. */
export function Markdown({ children }: { children: string }) {
  return (
    <div className="whitespace-normal break-words">
      <ReactMarkdown remarkPlugins={[remarkGfm]} components={components}>
        {children}
      </ReactMarkdown>
    </div>
  );
}
