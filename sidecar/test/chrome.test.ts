import { describe, expect, test } from "bun:test";
import { resolve } from "node:path";
import { trimAgentChrome } from "../src/chrome";

async function fixture(name: string): Promise<string> {
  return Bun.file(resolve(import.meta.dir, "fixtures", name)).text();
}

describe("trimAgentChrome", () => {
  test("trims the live Pi boxed input + footer and keeps the file box", async () => {
    const raw = await fixture("pi-tui-chrome.txt");
    const trimmed = trimAgentChrome(raw);
    expect(trimmed).toContain("PASS — Wave 4 live verification completed.");
    expect(trimmed).toContain("┏━━━");
    expect(trimmed).toContain("Composing final concise summary");
    expect(trimmed).not.toContain("╭─");
    expect(trimmed).not.toContain("╰─");
    expect(trimmed).not.toContain("pi-lens");
    expect(trimmed.endsWith("summary")).toBe(true);
  });

  test("strips ANSI before detecting the same chrome on a live ansi sample", async () => {
    const raw = await fixture("pi-tui-chrome.ansi.txt");
    const trimmed = trimAgentChrome(raw);
    expect(trimmed).toContain("Todos (0/1)");
    expect(trimmed).toContain("└─");
    expect(trimmed).not.toContain("╭");
    expect(trimmed).not.toContain("pi-lens");
  });

  test("shows more when the box is not at the tail", () => {
    const raw = ["╭─ prompt ──╮", "╰─ status ─╯", "pi-lens", "", "real output after"].join("\n");
    expect(trimAgentChrome(raw)).toBe(raw);
  });

  test("does not treat a todo tree as a box bottom", () => {
    const raw = ["work", "╭─ π ──╮", "└─ ○ #4 Resume", "more"].join("\n");
    expect(trimAgentChrome(raw)).toBe(raw);
  });
});
