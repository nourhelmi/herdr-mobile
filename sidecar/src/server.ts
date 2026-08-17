import type { Server, ServerWebSocket } from "bun";
import type { HerdrCli } from "./cli";
import { assertSafePositional, CliError, isUnknownTarget } from "./cli";
import type { StateEngine } from "./engine";
import type { Snapshot } from "./types";

interface PaneWatch {
  generation: number;
  paneId: string;
  lines: number;
  format: "text" | "ansi";
  lastText?: string;
  /** At most one extra read after the in-flight one; poke during a read sets this. */
  pokeQueued: boolean;
}

interface WebSocketData {
  watch: PaneWatch | null;
  timer?: ReturnType<typeof setTimeout>;
  generation: number;
  readQueue: Promise<void>;
  closed: boolean;
}

export const MAX_REQUEST_BODY_BYTES = 64 * 1024;
export const MAX_INPUT_TEXT_LENGTH = 16_000;
export const MAX_KEYS_COUNT = 32;
export const MAX_KEY_LENGTH = 128;
export const MAX_OUTPUT_LINES = 2_000;
export const MAX_LABEL_LENGTH = 128;
export const DEFAULT_OUTPUT_INTERVAL_MS = 100;

function json(value: unknown, status = 200): Response {
  return Response.json(value, { status });
}

function safeErrorMessage(error: unknown): string {
  if (typeof error === "string") return error;
  if (error instanceof TypeError) return error.message;
  if (isUnknownTarget(error)) return "Target not found";
  if (error instanceof CliError) return "Herdr command failed";
  return "Internal sidecar error";
}

function errorResponse(error: unknown): Response {
  const message = safeErrorMessage(error);
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

function validateInputText(text: string): void {
  if (text.length > MAX_INPUT_TEXT_LENGTH) {
    throw new TypeError(`text must not exceed ${MAX_INPUT_TEXT_LENGTH} characters`);
  }
  assertSafePositional(text, "text");
}

function paneIdForKeysTarget(snapshot: Snapshot, target: string): string {
  const byPane = snapshot.agents.find((agent) => agent.paneId === target);
  if (byPane) return byPane.paneId;
  const byName = snapshot.agents.find((agent) => agent.name === target);
  if (byName) return byName.paneId;
  return target;
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

function parseFormat(value: unknown, fallback: "text" | "ansi"): "text" | "ansi" {
  if (value === null || value === undefined || value === "") return fallback;
  if (value === "text" || value === "ansi") return value;
  throw new TypeError("format must be text or ansi");
}

/** Optional user label: length-capped, never flag-like. Empty omits the CLI flag. */
function validateLabel(value: unknown): string | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "string") throw new TypeError("label must be a string");
  if (value.length === 0) return undefined;
  if (value.length > MAX_LABEL_LENGTH) {
    throw new TypeError(`label must not exceed ${MAX_LABEL_LENGTH} characters`);
  }
  assertSafePositional(value, "label");
  return value;
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

/** Post-mutation freshness: 2xx only after poll succeeds. Partial success is 502. */
async function refreshAfterMutation(
  engine: StateEngine,
  forceStructure: boolean,
  completedAction: string,
): Promise<Response | undefined> {
  const refreshed = await engine.poll(forceStructure);
  if (refreshed) return undefined;
  return json(
    { ok: false, error: `${completedAction}, but state refresh failed; refresh before retrying` },
    502,
  );
}

async function handleHttp(
  request: Request,
  engine: StateEngine,
  cli: HerdrCli,
  pokePane: (paneId: string) => void,
): Promise<Response> {
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
      const format = parseFormat(url.searchParams.get("format"), "text");
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

  const acknowledgeMatch = url.pathname.match(/^\/agent\/([^/]+)\/acknowledge$/);
  if (request.method === "POST" && acknowledgeMatch) {
    try {
      const target = decodePathPart(acknowledgeMatch[1]!);
      assertSafePositional(target, "target");
      await cli.text(["agent", "focus", target]);
      const refreshError = await refreshAfterMutation(engine, false, "Agent was acknowledged");
      if (refreshError) return refreshError;
      return json({ ok: true });
    } catch (error) {
      if (error instanceof TypeError) return json({ ok: false, error: error.message }, 400);
      return errorResponse(error);
    }
  }

  if (request.method === "POST" && url.pathname === "/workspace") {
    try {
      const body = await readJsonBody(request);
      if (body !== null && (typeof body !== "object" || Array.isArray(body))) {
        return json({ ok: false, error: "body must be a JSON object" }, 400);
      }
      const label = validateLabel((body as { label?: unknown } | null)?.label);
      const args = ["workspace", "create"];
      if (label !== undefined) args.push("--label", label);
      await cli.text(args);
      const refreshError = await refreshAfterMutation(engine, true, "Workspace was created");
      if (refreshError) return refreshError;
      return json({ ok: true });
    } catch (error) {
      if (error instanceof TypeError) return json({ ok: false, error: error.message }, 400);
      return errorResponse(error);
    }
  }

  const tabCreateMatch = url.pathname.match(/^\/workspace\/([^/]+)\/tab$/);
  if (request.method === "POST" && tabCreateMatch) {
    try {
      const workspaceId = decodePathPart(tabCreateMatch[1]!);
      assertSafePositional(workspaceId, "workspaceId");
      const body = await readJsonBody(request);
      if (body !== null && (typeof body !== "object" || Array.isArray(body))) {
        return json({ ok: false, error: "body must be a JSON object" }, 400);
      }
      const label = validateLabel((body as { label?: unknown } | null)?.label);
      const args = ["tab", "create", "--workspace", workspaceId];
      if (label !== undefined) args.push("--label", label);
      await cli.text(args);
      const refreshError = await refreshAfterMutation(engine, true, "Tab was created");
      if (refreshError) return refreshError;
      return json({ ok: true });
    } catch (error) {
      if (error instanceof TypeError) return json({ ok: false, error: error.message }, 400);
      return errorResponse(error);
    }
  }

  const inputMatch = url.pathname.match(/^\/pane\/([^/]+)\/input$/);
  if (request.method === "POST" && inputMatch) {
    try {
      const paneId = decodePathPart(inputMatch[1]!);
      assertSafePositional(paneId, "paneId");
      const body = await readJsonBody(request);
      if (!body || typeof body !== "object" || typeof (body as { text?: unknown }).text !== "string") {
        return json({ ok: false, error: "text must be a string" }, 400);
      }
      const text = (body as { text: string }).text;
      validateInputText(text);
      await cli.text(["pane", "send-text", paneId, text]);
      pokePane(paneId);
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
      pokePane(paneIdForKeysTarget(engine.snapshot, target));
      return json({ ok: true });
    } catch (error) {
      if (error instanceof TypeError) return json({ ok: false, error: error.message }, 400);
      return errorResponse(error);
    }
  }

  const paneCloseMatch = url.pathname.match(/^\/pane\/([^/]+)$/);
  if (request.method === "DELETE" && paneCloseMatch) {
    try {
      const paneId = decodePathPart(paneCloseMatch[1]!);
      assertSafePositional(paneId, "paneId");
      await cli.text(["pane", "close", paneId]);
      const refreshError = await refreshAfterMutation(engine, true, "Pane was closed");
      if (refreshError) return refreshError;
      return json({ ok: true });
    } catch (error) {
      if (error instanceof TypeError) return json({ ok: false, error: error.message }, 400);
      return errorResponse(error);
    }
  }

  const tabCloseMatch = url.pathname.match(/^\/tab\/([^/]+)$/);
  if (request.method === "DELETE" && tabCloseMatch) {
    try {
      const tabId = decodePathPart(tabCloseMatch[1]!);
      assertSafePositional(tabId, "tabId");
      await cli.text(["tab", "close", tabId]);
      const refreshError = await refreshAfterMutation(engine, true, "Tab was closed");
      if (refreshError) return refreshError;
      return json({ ok: true });
    } catch (error) {
      if (error instanceof TypeError) return json({ ok: false, error: error.message }, 400);
      return errorResponse(error);
    }
  }

  const workspaceCloseMatch = url.pathname.match(/^\/workspace\/([^/]+)$/);
  if (request.method === "DELETE" && workspaceCloseMatch) {
    try {
      const workspaceId = decodePathPart(workspaceCloseMatch[1]!);
      assertSafePositional(workspaceId, "workspaceId");
      await cli.text(["workspace", "close", workspaceId]);
      const refreshError = await refreshAfterMutation(engine, true, "Workspace was closed");
      if (refreshError) return refreshError;
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
  const outputIntervalMs = options.outputIntervalMs ?? DEFAULT_OUTPUT_INTERVAL_MS;

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
        watch.format,
      ]);
      if (!isCurrentWatch(ws, watch)) return;
      if (force || text !== watch.lastText) {
        watch.lastText = text;
        ws.send(JSON.stringify({ type: "output", paneId: watch.paneId, text, format: watch.format }));
      }
    } catch (error) {
      if (!isCurrentWatch(ws, watch)) return;
      ws.send(JSON.stringify({ type: "error", message: safeErrorMessage(error) }));
    } finally {
      if (!isCurrentWatch(ws, watch)) return;
      // Poke during this read: one immediate follow-up, skip the interval.
      if (watch.pokeQueued) {
        watch.pokeQueued = false;
        queueOutput(ws, watch, false);
        return;
      }
      ws.data.timer = setTimeout(() => {
        ws.data.timer = undefined;
        queueOutput(ws, watch, false);
      }, outputIntervalMs);
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

  // Idle (timer pending) → cancel and read now. In-flight/queued → one follow-up.
  const pokePane = (paneId: string): void => {
    for (const ws of clients) {
      const watch = ws.data.watch;
      if (!watch || watch.paneId !== paneId) continue;
      if (!isCurrentWatch(ws, watch)) continue;
      if (ws.data.timer) {
        clearTimeout(ws.data.timer);
        ws.data.timer = undefined;
        queueOutput(ws, watch, false);
        continue;
      }
      watch.pokeQueued = true;
    }
  };

  const sendWsError = (ws: ServerWebSocket<WebSocketData>, error: unknown): void => {
    ws.send(JSON.stringify({ type: "error", message: safeErrorMessage(error) }));
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

      const value = message as { type?: unknown; paneId?: unknown; lines?: unknown; format?: unknown };
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
        const format = parseFormat(value.format, "text");
        clearWatch(ws);
        const watch: PaneWatch = {
          generation: ws.data.generation,
          paneId: value.paneId,
          lines,
          format,
          pokeQueued: false,
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
          return handleHttp(request, options.engine, options.cli, pokePane);
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
