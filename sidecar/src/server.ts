import type { Server, ServerWebSocket } from "bun";
import type { HerdrCli } from "./cli";
import { CliError, isUnknownTarget } from "./cli";
import type { StateEngine } from "./engine";
import type { Snapshot } from "./types";

interface PaneWatch {
  paneId: string;
  lines: number;
  lastText?: string;
}

interface WebSocketData {
  watch: PaneWatch | null;
  timer?: ReturnType<typeof setInterval>;
}

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

function parseLines(value: string | null, defaultValue: number): number {
  if (value === null) return defaultValue;
  const lines = Number(value);
  if (!Number.isSafeInteger(lines) || lines < 1) {
    throw new TypeError("lines must be a positive integer");
  }
  return lines;
}

async function readJsonBody(request: Request): Promise<unknown> {
  try {
    return await request.json();
  } catch {
    throw new TypeError("Request body must be valid JSON");
  }
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
      const body = await readJsonBody(request);
      if (!body || typeof body !== "object" || typeof (body as { text?: unknown }).text !== "string") {
        return json({ ok: false, error: "text must be a string" }, 400);
      }
      await cli.text(["agent", "prompt", target, (body as { text: string }).text]);
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
      const body = await readJsonBody(request);
      const keys = body && typeof body === "object" ? (body as { keys?: unknown }).keys : undefined;
      if (!Array.isArray(keys) || keys.length === 0 || !keys.every((key) => typeof key === "string")) {
        return json({ ok: false, error: "keys must be a non-empty string array" }, 400);
      }
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
  const clients = new Set<ServerWebSocket<WebSocketData>>();
  const outputIntervalMs = options.outputIntervalMs ?? 2_000;

  const pushOutput = async (ws: ServerWebSocket<WebSocketData>, force: boolean): Promise<void> => {
    const watch = ws.data.watch;
    if (!watch) return;
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
      if (force || text !== watch.lastText) {
        watch.lastText = text;
        ws.send(JSON.stringify({ type: "output", paneId: watch.paneId, text, format: "text" }));
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      ws.send(JSON.stringify({ type: "error", message }));
    }
  };

  const websocket = {
    open(ws: ServerWebSocket<WebSocketData>) {
      clients.add(ws);
      ws.send(JSON.stringify({ type: "state", state: options.engine.snapshot }));
    },
    message(ws: ServerWebSocket<WebSocketData>, raw: string | Buffer) {
      void (async () => {
        let message: unknown;
        try {
          message = JSON.parse(typeof raw === "string" ? raw : raw.toString());
        } catch {
          ws.send(JSON.stringify({ type: "error", message: "Message must be valid JSON" }));
          return;
        }

        if (!message || typeof message !== "object") {
          ws.send(JSON.stringify({ type: "error", message: "Message must be an object" }));
          return;
        }

        const value = message as { type?: unknown; paneId?: unknown; lines?: unknown };
        if (value.type === "unwatch") {
          if (ws.data.timer) clearInterval(ws.data.timer);
          ws.data.timer = undefined;
          ws.data.watch = null;
          return;
        }
        if (value.type !== "watch") {
          ws.send(JSON.stringify({ type: "error", message: "Unknown message type" }));
          return;
        }
        if (typeof value.paneId !== "string" || value.paneId.length === 0) {
          ws.send(JSON.stringify({ type: "error", message: "paneId must be a non-empty string" }));
          return;
        }
        const lines = value.lines === undefined ? 200 : Number(value.lines);
        if (!Number.isSafeInteger(lines) || lines < 1) {
          ws.send(JSON.stringify({ type: "error", message: "lines must be a positive integer" }));
          return;
        }

        if (ws.data.timer) clearInterval(ws.data.timer);
        ws.data.watch = { paneId: value.paneId, lines };
        await pushOutput(ws, true);
        ws.data.timer = setInterval(() => void pushOutput(ws, false), outputIntervalMs);
      })();
    },
    close(ws: ServerWebSocket<WebSocketData>) {
      clients.delete(ws);
      if (ws.data.timer) clearInterval(ws.data.timer);
    },
  };

  const servers: Server<WebSocketData>[] = [];
  for (const host of [...new Set(options.hosts)]) {
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
            return server.upgrade(request, { data: { watch: null } })
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
      for (const client of clients) client.close();
      for (const server of servers) server.stop(true);
    },
  };
}
