import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import ts from "typescript";
import { expect, it } from "vitest";

const displayAttributes = new Set([
  "aria-label",
  "title",
  "placeholder",
  "description",
  "label",
  "closeLabel",
  "confirmLabel",
  "cancelLabel",
  "sub",
]);

function sourceFiles(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) return entry.name === "__tests__" ? [] : sourceFiles(file);
    return /\.(ts|tsx)$/.test(entry.name) && !entry.name.includes(".test.") ? [file] : [];
  });
}

function inlineCopy(file: string, text: string): string[] {
  const source = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true);
  const violations: string[] = [];
  function report(node: ts.Node) {
    const line = source.getLineAndCharacterOfPosition(node.getStart(source)).line + 1;
    violations.push(
      `${path.relative(process.cwd(), file)}:${line}: ${node.getText(source).trim()}`
    );
  }
  function visit(node: ts.Node) {
    if (ts.isJsxText(node) && /\p{L}/u.test(node.text)) report(node);
    if (
      ts.isJsxAttribute(node) &&
      displayAttributes.has(node.name.getText(source)) &&
      node.initializer &&
      ts.isStringLiteral(node.initializer) &&
      /\p{L}/u.test(node.initializer.text)
    )
      report(node);
    if (
      ts.isNewExpression(node) &&
      node.expression.getText(source) === "Error" &&
      node.arguments?.[0] &&
      (ts.isStringLiteral(node.arguments[0]) ||
        ts.isNoSubstitutionTemplateLiteral(node.arguments[0]) ||
        ts.isTemplateExpression(node.arguments[0]))
    )
      report(node);
    if (
      ts.isJsxExpression(node) &&
      node.expression &&
      (!ts.isJsxAttribute(node.parent) || displayAttributes.has(node.parent.name.getText(source)))
    ) {
      const expression = node.expression;
      if (
        (ts.isStringLiteral(expression) || ts.isNoSubstitutionTemplateLiteral(expression)) &&
        /\p{L}/u.test(expression.text)
      )
        report(node);
      if (
        ts.isTemplateExpression(expression) &&
        [expression.head.text, ...expression.templateSpans.map((span) => span.literal.text)].some(
          (text) => /\p{L}/u.test(text)
        )
      )
        report(node);
    }
    ts.forEachChild(node, visit);
  }
  visit(source);
  return violations;
}

it("keeps UI text, accessible labels and application errors in the translation catalogs", () => {
  const violations = sourceFiles(path.join(process.cwd(), "src")).flatMap((file) =>
    inlineCopy(file, readFileSync(file, "utf8"))
  );
  expect(violations).toEqual([]);
});

it("detects newly introduced inline copy", () => {
  expect(inlineCopy("example.tsx", '<button aria-label="Save feature">Save</button>')).toHaveLength(
    2
  );
  expect(inlineCopy("example.ts", 'throw new Error("Please sign in")')).toHaveLength(1);
  expect(inlineCopy("example.tsx", '<button aria-label={t("save")}>{t("save")}</button>')).toEqual(
    []
  );
});
