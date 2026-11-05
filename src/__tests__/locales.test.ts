import { describe, expect, it } from "vitest";
import ts from "typescript";
import { APP_LANGUAGES } from "@jordiorriols/ui";
import i18n from "@/i18n";
import en from "@/locales/en.json";

type Messages = { [key: string]: string | Messages };

const flatten = (messages: Messages, prefix = ""): [string, string][] =>
  Object.entries(messages).flatMap(([key, value]) =>
    typeof value === "string" ? [[prefix + key, value]] : flatten(value, `${prefix}${key}.`)
  );
const placeholders = (value: string) => (value.match(/{{\s*\w+\s*}}/g) ?? []).sort();
const english = flatten(en);

describe("locales", () => {
  it.each(APP_LANGUAGES.map((language) => language.code))(
    "%s translates every English message with the same placeholders",
    (code) => {
      const bundle = i18n.getResourceBundle(code, "translation") as Messages | undefined;
      expect(bundle, `missing ${code} resources`).toBeDefined();
      const messages = new Map(flatten(bundle!));
      expect(bundle).not.toHaveProperty("copy");
      for (const [key, value] of english) {
        expect(messages.get(key), `${code}: ${key}`).toBeTruthy();
        expect(placeholders(messages.get(key)!), `${code}: ${key}`).toEqual(placeholders(value));
        expect(
          messages.get(key),
          `${code}: ${key} needs meaningful interpolation names`
        ).not.toMatch(/{{\s*(?:value|var|param)\d*\s*}}/);
      }
    }
  );

  it("resolves every literal translation reference with its arguments", () => {
    const files = import.meta.glob<string>("../**/*.{ts,tsx}", {
      query: "?raw",
      import: "default",
      eager: true,
    });
    const messages = new Map(english);
    const missing: string[] = [];
    const missingArguments: string[] = [];
    for (const [file, text] of Object.entries(files)) {
      if (file.includes("__tests__") || file.includes(".test.")) continue;
      const source = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true);
      function visit(node: ts.Node) {
        if (
          ts.isCallExpression(node) &&
          ["t", "i18n.t"].includes(node.expression.getText(source)) &&
          node.arguments[0] &&
          ts.isStringLiteral(node.arguments[0])
        ) {
          const key = node.arguments[0].text;
          if (!messages.has(key) && !messages.has(`${key}_one`) && !messages.has(`${key}_other`))
            missing.push(`${file}: ${key}`);
          const message =
            messages.get(key) ?? messages.get(`${key}_other`) ?? messages.get(`${key}_one`);
          const options = node.arguments[1];
          const supplied =
            options && ts.isObjectLiteralExpression(options)
              ? new Set(
                  options.properties.flatMap((property) =>
                    ts.isPropertyAssignment(property) || ts.isShorthandPropertyAssignment(property)
                      ? [property.name.getText(source)]
                      : []
                  )
                )
              : new Set<string>();
          for (const placeholder of message?.matchAll(/{{\s*(\w+)\s*}}/g) ?? []) {
            if (!supplied.has(placeholder[1]!))
              missingArguments.push(`${file}: ${key} requires ${placeholder[1]}`);
          }
        }
        ts.forEachChild(node, visit);
      }
      visit(source);
      expect(text, `${file} uses the old namespace`).not.toContain("copy.");
    }
    expect(missing).toEqual([]);
    expect(missingArguments).toEqual([]);
  });
});
