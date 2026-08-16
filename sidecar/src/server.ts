import type { Server, ServerWebSocket } from "bun";
import type { HerdrCli } from "./cli";
import { assertSafePositional, CliError, isUnknownTarget } from "./cli";
import type { StateEngine } from "./engine";
import type { Snapshot } from "./types";

interface PaneWatch {
  generation: number;
  paneId: string;
  lines: number;
  lastText?: string;
}

interface WebSocketData {
  watch: PaneWatch | null;
  timer?: ReturnType<typeof setTimeout>;
  generation: number;
  readQueue: Promise<void>;
  closed: boolean;
}

export const MAX_REQUEST_BODY_BYTES = 64 * 1024;
export const MAX_PROMPT_TEXT_LENGTH = 16_000;
export const MAX_KEYS_COUNT = 32;
export const MAX_KEY_LENGTH = 128;
export const MAX_OUTPUT_LINES = 2_000;

function json(value: unknown, status = 200): Response {
  return Response.json(value, { status });
}

function errorResponse(error: unknown): Response {
  const message = error instanceof Error ? error.message : String(error);
  if (isUnknownTarget(error)) return json({ ok: false, error: message }, 404);
  if (error instanceof CliError) return json({ ok: false, error: message }, 502);
  return json({ ok: false, error: message }, 500);
}

function decodePathPart(value: string): string {
  try {
    return decodeURIComponent(value);
  } catch {
    throw new TypeError("Invalid URL encoding");
  }
}

function parseLines(value: unknown, defaultValue: number): number {
  if (value === null || value === undefined) return defaultValue;
  const lines = typeof value === "number"
    ? value
    : typeof value === "string" && /^\d+$/.test(value)
      ? Number(value)
      : Number.NaN;
  if (!Number.isSafeInteger(lines) || lines < 1 || lines > MAX_OUTPUT_LINES) {
    throw new TypeError(`lines must be an integer between 1 and ${MAX_OUTPUT_LINES}`);
  }
  return lines;
}

async function readJsonBody(request: Request): Promise<unknown> {
  const contentLength = request.headers.get("content-length");
  if (contentLength !== null) {
    const declaredBytes = Number(contentLength);
    if (!Number.isSafeInteger(declaredBytes) || declaredBytes < 0) {
      throw new TypeError("Content-Length must be a non-negative integer");
    }
    if (declaredBytes > MAX_REQUEST_BODY_BYTES) {
      throw new TypeError(`Request body must not exceed ${MAX_REQUEST_BODY_BYTES} bytes`);
    }
  }

  if (!request.body) throw new TypeError("Request body must be valid JSON");
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let totalBytes = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    totalBytes += value.byteLength;
    if (totalBytes > MAX_REQUEST_BODY_BYTES) {
      await reader.cancel().catch(() => undefined);
      throw new TypeError(`Request body must not exceed ${MAX_REQUEST_BODY_BYTES} bytes`);
    }
    chunks.push(value);
  }

  const bytes = new Uint8Array(totalBytes);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }

  try {
    const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    return JSON.parse(text) as unknown;
  } catch {
    throw new TypeError("Request body must be valid JSON");
  }
}

function validatePromptText(text: string): void {
  if (text.length > MAX_PROMPT_TEXT_LENGTH) {
    throw new TypeError(`text must not exceed ${MAX_PROMPT_TEXT_LENGTH} characters`);
  }
  assertSafePositional(text, "text");
}

function validateKeys(keys: string[]): void {
  if (keys.length > MAX_KEYS_COUNT) {
    throw new TypeError(`keys must contain at most ${MAX_KEYS_COUNT} elements`);
  }
  for (const key of keys) {
    if (key.length > MAX_KEY_LENGTH) {
      throw new TypeError(`each key must not exceed ${MAX_KEY_LENGTH} characters`);
    }
    assertSafePositional(key, "key");
  }
}

/** Exact 127.0.0.1 or numerically-parsed unicast IPv4. Rejects wildcards, multicast, class-E, IPv6. */
export function isSafeTailscaleIpv4(value: string): boolean {
  if (value === "127.0.0.1") return true;
  const parts = value.split(".");
  if (parts.length !== 4 || parts.some((part) => !/^\d{1,3}$/.test(part))) return false;
  const octets = parts.map(Number);
  if (octets.some((octet) => !Number.isInteger(octet) || octet < 0 || octet > 255)) return false;
  const [a, b, c, d] = octets;
  if (a === 0 && b === 0 && c === 0 && d === 0) return false;
  if (a === 255 && b === 255 && c === 255 && d === 255) return false;
  if (a >= 224) return false;
  return true;
}

async function handleHttp(request: Request, engine: StateEngine, cli: HerdrCli): Promise<Response> {
  let url: URL;
  try {
    url = new URL(request.url);
  } catch {
    return json({ ok: false, error: "Invalid request URL" }, 400);
  }

  if (request.method === "GET" && url.pathname === "/health") {
    return json({ ok: true, version: "1.0.0", herdr: engine.herdrOk });
  }
  if (request.method === "GET" && url.pathname === "/state") {
    return json(engine.snapshot);
  }

  const outputMatch = url.pathname.match(/^\/pane\/([^/]+)\/output$/);
  if (request.method === "GET" && outputMatch) {
    try {
      const paneId = decodePathPart(outputMatch[1]!);
      assertSafePositional(paneId, "paneId");
      const lines = parseLines(url.searchParams.get("lines"), 200);
      const format = url.searchParams.get("format") ?? "text";
      if (format !== "text" && format !== "ansi") {
        return json({ ok: false, error: "format must be text or ansi" }, 400);
      }
      const text = await cli.text([
        "pane",
        "read",
        paneId,
        "--source",
        "recent-unwrapped",
        "--lines",
        String(lines),
        "--format",
        format,
      ]);
      return json({ paneId, format, text });
    } catch (error) {
      if (error instanceof TypeError) return json({ ok: false, error: error.message }, 400);
      return errorResponse(error);
    }
  }

  const promptMatch = url.pathname.match(/^\/agent\/([^/]+)\/prompt$/);
  if (request.method === "POST" && promptMatch) {
    try {
      const target = decodePathPart(promptMatch[1]!);
      assertSafePositional(target, "target");
      const body = await readJsonBody(request);
      if (!body || typeof body !== "object" || typeof (body as { text?: unknown }).text !== "string") {
        return json({ ok: false, error: "text must be a string" }, 400);
      }
      const text = (body as { text: string }).text;
      validatePromptText(text);
      await cli.text(["agent", "prompt", target, text]);
      return json({ ok: true });
    } catch (error) {
      if (error instanceof TypeError) return json({ ok: false, error: error.message }, 400);
      return errorResponse(error);
    }
  }

  const keysMatch = url.pathname.match(/^\/agent\/([^/]+)\/keys$/);
  if (request.method === "POST" && keysMatch) {
    try {
      const target = decodePathPart(keysMatch[1]!);
      assertSafePositional(target, "target");
      const body = await readJsonBody(request);
      const keys = body && typeof body === "object" ? (body as { keys?: unknown }).keys : undefined;
      if (!Array.isArray(keys) || keys.length === 0 || !keys.every((key) => typeof key === "string")) {
        return json({ ok: false, error: "keys must be a non-empty string array" }, 400);
      }
      validateKeys(keys);
      await cli.text(["agent", "send-keys", target, ...keys]);
      return json({ ok: true });
    } catch (error) {
      if (error instanceof TypeError) return json({ ok: false, error: error.message }, 400);
      return errorResponse(error);
    }
  }

  return json({ ok: false, error: "Not found" }, 404);
}

export interface RunningSidecar {
  servers: Server<WebSocketData>[];
  stop(): void;
}

export function startSidecar(options: {
  engine: StateEngine;
  cli: HerdrCli;
  hosts: string[];
  port: number;
  outputIntervalMs?: number;
  pingIntervalMs?: number;
}): RunningSidecar {
  const uniqueHosts = [...new Set(options.hosts)];
  const unsafeHost = uniqueHosts.find((host) => !isSafeTailscaleIpv4(host));
  if (unsafeHost !== undefined) {
    throw new TypeError(`Refusing to bind unauthenticated sidecar to host '${unsafeHost}'`);
  }

  const clients = new Set<ServerWebSocket<WebSocketData>>();
  const outputIntervalMs = options.outputIntervalMs ?? 2_000;

  const isCurrentWatch = (ws: ServerWebSocket<WebSocketData>, watch: PaneWatch): boolean =>
    !ws.data.closed && ws.data.watch?.generation === watch.generation;

  const clearWatch = (ws: ServerWebSocket<WebSocketData>, closed = false): void => {
    ws.data.generation += 1;
    if (ws.data.timer) clearTimeout(ws.data.timer);
    ws.data.timer = undefined;
    ws.data.watch = null;
    if (closed) ws.data.closed = true;
  };

  const pushOutput = async (
    ws: ServerWebSocket<WebSocketData>,
    watch: PaneWatch,
    force: boolean,
  ): Promise<void> => {
    if (!isCurrentWatch(ws, watch)) return;
    try {
      const text = await options.cli.text([
        "pane",
        "read",
        watch.paneId,
        "--source",
        "recent-unwrapped",
        "--lines",
        String(watch.lines),
        "--format",
        "text",
      ]);
      if (!isCurrentWatch(ws, watch)) return;
      if (force || text !== watch.lastText) {
        watch.lastText = text;
        ws.send(JSON.stringify({ type: "output", paneId: watch.paneId, text, format: "text" }));
      }
    } catch (error) {
      if (!isCurrentWatch(ws, watch)) return;
      const message = error instanceof Error ? error.message : String(error);
      ws.send(JSON.stringify({ type: "error", message }));
    } finally {
      if (isCurrentWatch(ws, watch)) {
        ws.data.timer = setTimeout(() => {
          ws.data.timer = undefined;
          queueOutput(ws, watch, false);
        }, outputIntervalMs);
      }
    }
  };

  const queueOutput = (
    ws: ServerWebSocket<WebSocketData>,
    watch: PaneWatch,
    force: boolean,
  ): void => {
    const run = () => pushOutput(ws, watch, force);
    ws.data.readQueue = ws.data.readQueue.then(run, run);
  };

  const sendWsError = (ws: ServerWebSocket<WebSocketData>, error: unknown): void => {
    const message = error instanceof Error ? error.message : String(error);
    ws.send(JSON.stringify({ type: "error", message }));
  };

  const websocket = {
    open(ws: ServerWebSocket<WebSocketData>) {
      clients.add(ws);
      ws.send(JSON.stringify({ type: "state", state: options.engine.snapshot }));
    },
    message(ws: ServerWebSocket<WebSocketData>, raw: string | Buffer) {
      let message: unknown;
      try {
        message = JSON.parse(typeof raw === "string" ? raw : raw.toString());
      } catch {
        sendWsError(ws, "Message must be valid JSON");
        return;
      }

      if (!message || typeof message !== "object") {
        sendWsError(ws, "Message must be an object");
        return;
      }

      const value = message as { type?: unknown; paneId?: unknown; lines?: unknown };
      if (value.type === "unwatch") {
        clearWatch(ws);
        return;
      }
      if (value.type !== "watch") {
        sendWsError(ws, "Unknown message type");
        return;
      }

      try {
        if (typeof value.paneId !== "string" || value.paneId.length === 0) {
          throw new TypeError("paneId must be a non-empty string");
        }
        assertSafePositional(value.paneId, "paneId");
        const lines = parseLines(value.lines, 200);
        clearWatch(ws);
        const watch: PaneWatch = {
          generation: ws.data.generation,
          paneId: value.paneId,
          lines,
        };
        ws.data.watch = watch;
        queueOutput(ws, watch, true);
      } catch (error) {
        sendWsError(ws, error);
      }
    },
    close(ws: ServerWebSocket<WebSocketData>) {
      clients.delete(ws);
      clearWatch(ws, true);
    },
  };

  const servers: Server<WebSocketData>[] = [];
  for (const host of uniqueHosts) {
    try {
      const server = Bun.serve<WebSocketData>({
        hostname: host,
        port: options.port,
        fetch(request, server) {
          let url: URL;
          try {
            url = new URL(request.url);
          } catch {
            return json({ ok: false, error: "Invalid request URL" }, 400);
          }
          if (request.method === "GET" && url.pathname === "/ws") {
            return server.upgrade(request, {
              data: {
                watch: null,
                generation: 0,
                readQueue: Promise.resolve(),
                closed: false,
              },
            })
              ? undefined
              : json({ ok: false, error: "WebSocket upgrade failed" }, 400);
          }
          return handleHttp(request, options.engine, options.cli);
        },
        websocket,
      });
      servers.push(server);
      console.log(`Herdr sidecar listening on http://${host}:${options.port}`);
    } catch (error) {
      if (host === "127.0.0.1") throw error;
      console.warn(`Could not bind Tailscale address ${host}:`, error);
    }
  }

  const unsubscribe = options.engine.subscribe((snapshot: Snapshot) => {
    const message = JSON.stringify({ type: "state", state: snapshot });
    for (const client of clients) client.send(message);
  });
  const pingTimer = setInterval(() => {
    for (const client of clients) client.ping();
  }, options.pingIntervalMs ?? 30_000);

  return {
    servers,
    stop() {
      unsubscribe();
      clearInterval(pingTimer);
      for (const client of clients) {
        clearWatch(client, true);
        client.close();
      }
      clients.clear();
      for (const server of servers) server.stop(true);
    },
  };
}
