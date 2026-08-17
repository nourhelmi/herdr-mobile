import { describe, expect, test } from "bun:test";
import { resolve } from "node:path";
import { displayText, parseDisplayAgent, sanitizePrivateUse } from "../src/display";
import type { RawAgent } from "../src/types";

const captured = "\u03C0 \uE0B0 \uF2DB gpt-5.6-luna \uE0B0 \uF07B herdr-mobile \uE0B0 \uE0A0 main \uE0B0 \uF155 $0.56";

describe("sanitizePrivateUse", () => {
  test("drops Powerline/Nerd PUA pairs and keeps \u03C0, ASCII, and cost", () => {
    expect(sanitizePrivateUse(captured)).toBe("\u03C0 gpt-5.6-luna herdr-mobile main $0.56");
    expect(displayText(captured)).toBe("\u03C0 \u00B7 gpt-5.6-luna \u00B7 herdr-mobile \u00B7 main \u00B7 $0.56");
  });

  test("keeps box drawing, emoji, and supplementary-plane non-PUA", () => {
    const raw = "\u2514\u2500 \u25CB 29.4%/1M  8h33m  high  \u{1F500} \u{1F50C} \u{1F9E0}";
    expect(sanitizePrivateUse(raw)).toBe("\u2514\u2500 \u25CB 29.4%/1M 8h33m high \u{1F500} \u{1F50C} \u{1F9E0}");
  });

  test("drops supplementary PUA used by Pi footer icons", () => {
    // U+F051B and U+F09D1 from a live `herdr pane read` footer.
    const raw = "\u25D4 17.1%/272k \u{F051B} 38m \u{F09D1} max";
    expect(sanitizePrivateUse(raw)).toBe("\u25D4 17.1%/272k 38m max");
    expect(sanitizePrivateUse(raw).includes("\uFFFD")).toBe(false);
  });
});

describe("parseDisplayAgent", () => {
  test("parses live Herdr display_agent fields", () => {
    expect(parseDisplayAgent(captured)).toEqual({
      text: "\u03C0 \u00B7 gpt-5.6-luna \u00B7 herdr-mobile \u00B7 main \u00B7 $0.56",
      model: "gpt-5.6-luna",
      repo: "herdr-mobile",
      branch: "main",
      cost: "$0.56",
    });
  });

  test("parses fixture agents including the no-branch form", async () => {
    const envelope = (await Bun.file(resolve(import.meta.dir, "fixtures", "agents.json")).json()) as {
      result: { agents: RawAgent[] };
    };
    const withBranch = envelope.result.agents.find((agent) => agent.pane_id === "w1:pDF");
    const noBranch = envelope.result.agents.find((agent) => agent.pane_id === "w4:p1");
    expect(parseDisplayAgent(withBranch?.display_agent)).toMatchObject({
      model: "claude-fable-5",
      repo: "sample-api",
      branch: "main",
      cost: "$0.00",
    });
    expect(parseDisplayAgent(noBranch?.display_agent)).toMatchObject({
      model: "claude-fable-5",
      repo: "startups",
      branch: null,
      cost: "$0.00",
    });
  });
});
