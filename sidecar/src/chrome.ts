/**
 * Conservative Pi TUI chrome trim.
 * Only cuts a bottom-anchored input box (`╭`/`┌` … `╰`/`└…┘`) plus trailing footer.
 * When the pair is missing or not near EOF, return the original text.
 */

const MAX_BOX_SPAN_LINES = 16;
const MAX_FOOTER_LINES = 8;

function stripAnsi(text: string): string {
  return text
    .replace(/\u001B\[[0-9;?]*[ -/]*[@-~]/g, "")
    .replace(/\u001B\][^\u0007\u001B]*(?:\u0007|\u001B\\)/g, "")
    .replace(/\u001B[@-Z\\-_]/g, "")
    .replace(/[\u009B\u009D][^\u0007]*/g, "");
}

function plainLine(line: string): string {
  return stripAnsi(line).replace(/\r/g, "").trimEnd();
}

function isBoxTop(plain: string): boolean {
  const trimmed = plain.trimStart();
  return trimmed.startsWith("╭") || trimmed.startsWith("┌");
}

/** `╰…` is the Pi footer; `└…┘` is a closed box. Bare `└─ ○` todos are not chrome. */
function isBoxBottom(plain: string): boolean {
  const trimmed = plain.trim();
  if (trimmed.startsWith("╰")) return true;
  return /^└[─┬┴┼─\s].*┘$/.test(trimmed);
}

function isFooterLine(plain: string): boolean {
  const trimmed = plain.trim();
  if (trimmed.length === 0) return true;
  if (/^pi-lens\b/i.test(trimmed)) return true;
  if (/^(checker|orchestrator)\b/i.test(trimmed)) return true;
  // Indented lens continuation (`   ! file.md`, ` · MCP`).
  return plain.startsWith(" ") || plain.startsWith("\t");
}

export function trimAgentChrome(text: string): string {
  const normalized = text.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
  const lines = normalized.split("\n");
  if (lines.length < 3) return text;

  const plains = lines.map(plainLine);
  let top = -1;
  for (let index = plains.length - 1; index >= 0; index -= 1) {
    if (isBoxTop(plains[index]!)) {
      top = index;
      break;
    }
  }
  if (top < 0) return text;

  let bottom = -1;
  for (let index = top + 1; index < plains.length; index += 1) {
    if (isBoxBottom(plains[index]!)) {
      bottom = index;
      break;
    }
  }
  if (bottom < 0) return text;

  const span = bottom - top + 1;
  const trailing = plains.slice(bottom + 1);
  // Unsure → show more. Box stays short and nothing after it looks like body.
  if (span > MAX_BOX_SPAN_LINES) return text;
  if (trailing.length > MAX_FOOTER_LINES) return text;
  if (!trailing.every(isFooterLine)) return text;

  const kept = lines.slice(0, top);
  while (kept.length > 0 && kept[kept.length - 1] === "") kept.pop();
  return kept.join("\n");
}
