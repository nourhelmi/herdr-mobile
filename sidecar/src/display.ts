import type { AgentDisplay } from "./types";

/** BMP PUA + supplementary PUA-A/B — Nerd Font / Powerline live here. */
export function isPrivateUse(codePoint: number): boolean {
  return (
    (codePoint >= 0xe000 && codePoint <= 0xf8ff) ||
    (codePoint >= 0xf0000 && codePoint <= 0xffffd) ||
    (codePoint >= 0x100000 && codePoint <= 0x10fffd)
  );
}

/** Drop PUA scalars. Real Unicode (π, box drawing, emoji, $) stays. */
export function sanitizePrivateUse(text: string): string {
  let output = "";
  for (const scalar of text) {
    const codePoint = scalar.codePointAt(0);
    if (codePoint !== undefined && isPrivateUse(codePoint)) {
      if (output.length > 0 && !output.endsWith(" ")) output += " ";
      continue;
    }
    output += scalar;
  }
  return output.replace(/[ \t]{2,}/g, " ").trim();
}

/** Join remaining tokens with a field-log separator after PUA icons are gone. */
export function displayText(raw: string): string {
  const sanitized = sanitizePrivateUse(raw);
  return sanitized.replace(/ +/g, " · ").replace(/(?: · ){2,}/g, " · ");
}

/**
 * Herdr `display_agent` is `π   model   repo   branch   $cost`.
 * Split on PUA runs so Home/chips do not depend on Nerd Font glyphs.
 */
export function parseDisplayAgent(raw: string | null | undefined): AgentDisplay {
  if (!raw) {
    return { text: "", model: null, repo: null, branch: null, cost: null };
  }

  const tokens: string[] = [];
  let current = "";
  for (const scalar of raw) {
    const codePoint = scalar.codePointAt(0);
    if (codePoint !== undefined && isPrivateUse(codePoint)) {
      const token = current.trim();
      if (token) tokens.push(token);
      current = "";
      continue;
    }
    current += scalar;
  }
  const last = current.trim();
  if (last) tokens.push(last);

  const costIndex = tokens.findIndex((token) => /^\$[\d.]+/.test(token));
  const cost = costIndex >= 0 ? tokens[costIndex]! : null;
  const body = tokens.filter((_, index) => index !== costIndex);
  // First token is the agent mark (`π`); remaining are model / repo / branch.
  const fields = body[0] === "π" || body[0] === "pi" ? body.slice(1) : body;

  return {
    text: displayText(raw),
    model: fields[0] ?? null,
    repo: fields[1] ?? null,
    branch: fields[2] ?? null,
    cost,
  };
}
