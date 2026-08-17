import { afterEach, describe, expect, test } from "bun:test";
import { CliError, type HerdrCli } from "../src/cli";
import type { StateEngine } from "../src/engine";
import {
  DEFAULT_OUTPUT_INTERVAL_MS,
  isSafeTailscaleIpv4,
  MAX_KEYS_COUNT,
  MAX_KEY_LENGTH,
  MAX_LABEL_LENGTH,
  MAX_OUTPUT_LINES,
  MAX_PROMPT_TEXT_LENGTH,
  MAX_REQUEST_BODY_BYTES,
  type RunningSidecar,
  startSidecar,
} from "../src/server";
import type { Snapshot } from "../src/types";

const snapshot: Snapshot = {
  generatedAt: "2026-08-16T12:00:00.000Z",
  workspaces: [],
  agents: [],
};

class FakeEngine {
  herdrOk = true;
  snapshot = snapshot;
  pollCalls: boolean[] = [];
  pollResult = true;
  private listeners = new Set<(value: Snapshot) => void>();

  subscribe(listener: (value: Snapshot) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  async poll(forceStructure: boolean): Promise<boolean> {
    this.pollCalls.push(forceStructure);
    return this.pollResult;
  }
}

interface PendingRead {
  paneId: string;
  resolve(text: string): void;
  reject(error: Error): void;
}

class FakeCli implements HerdrCli {
  readonly calls: string[][] = [];
  readonly pendingReads: PendingRead[] = [];
  deferPaneReads = false;
  activeReads = 0;
  maxActiveReads = 0;

  async json<T>(_args: string[]): Promise<T> {
    throw new Error("FakeCli.json is not used by server integration tests");
  }

  async text(args: string[]): Promise<string> {
    this.calls.push([...args]);
    const target = args[2];
    if (target === "missing") throw new CliError("target not found", 1);
    if (target === "failure") throw new CliError("herdr failed with secret=top-secret", 1);

    if (args[0] === "pane" && args[1] === "read") {
      if (!this.deferPaneReads) return `output:${target}`;
      this.activeReads += 1;
      this.maxActiveReads = Math.max(this.maxActiveReads, this.activeReads);
      try {
        return await new Promise<string>((resolve, reject) => {
          this.pendingReads.push({ paneId: target!, resolve, reject });
        });
      } finally {
        this.activeReads -= 1;
      }
    }
    return "";
  }

  resolveNextRead(text: string): void {
    const read = this.pendingReads.shift();
    if (!read) throw new Error("No pending pane read");
    read.resolve(text);
  }
}

const running: RunningSidecar[] = [];
const sockets: WebSocket[] = [];

afterEach(() => {
  for (const socket of sockets.splice(0)) socket.close();
  for (const sidecar of running.splice(0)) sidecar.stop();
});

function startTestServer(cli = new FakeCli(), outputIntervalMs = 100) {
  const engine = new FakeEngine();
  const sidecar = startSidecar({
    engine: engine as unknown as StateEngine,
    cli,
    hosts: ["127.0.0.1"],
    port: 0,
    outputIntervalMs,
    pingIntervalMs: 60_000,
  });
  running.push(sidecar);
  const port = sidecar.servers[0]!.port;
  return { cli, engine, sidecar, baseUrl: `http://127.0.0.1:${port}` };
}

async function jsonResponse(response: Response): Promise<Record<string, unknown>> {
  return response.json() as Promise<Record<string, unknown>>;
}

async function waitUntil(predicate: () => boolean, message: string, timeoutMs = 1_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(`Timed out waiting for ${message}`);
    await Bun.sleep(5);
  }
}

async function connectWebSocket(baseUrl: string): Promise<{
  socket: WebSocket;
  messages: Array<Record<string, unknown>>;
}> {
  const messages: Array<Record<string, unknown>> = [];
  const socket = new WebSocket(`${baseUrl.replace("http://", "ws://")}/ws`);
  sockets.push(socket);
  socket.addEventListener("message", (event) => {
    messages.push(JSON.parse(String(event.data)) as Record<string, unknown>);
  });
  await new Promise<void>((resolve, reject) => {
    socket.addEventListener("open", () => resolve(), { once: true });
    socket.addEventListener("error", () => reject(new Error("WebSocket connection failed")), {
      once: true,
    });
  });
  await waitUntil(() => messages.some((message) => message.type === "state"), "initial state");
  return { socket, messages };
}

function send(socket: WebSocket, value: unknown): void {
  socket.send(JSON.stringify(value));
}

describe("sidecar HTTP integration", () => {
  test("serves all five endpoints with the frozen shapes and safe argv", async () => {
    const { baseUrl, cli, engine } = startTestServer();

    const health = await fetch(`${baseUrl}/health`);
    expect(health.status).toBe(200);
    expect(await jsonResponse(health)).toEqual({ ok: true, version: "1.0.0", herdr: true });

    engine.herdrOk = false;
    const unhealthy = await fetch(`${baseUrl}/health`);
    expect(await jsonResponse(unhealthy)).toMatchObject({ ok: true, herdr: false });

    const state = await fetch(`${baseUrl}/state`);
    expect(state.status).toBe(200);
    expect(await state.json()).toEqual(snapshot);

    const output = await fetch(`${baseUrl}/pane/w1%3Ap1/output?lines=42&format=ansi`);
    expect(output.status).toBe(200);
    expect(await jsonResponse(output)).toEqual({
      paneId: "w1:p1",
      format: "ansi",
      text: "output:w1:p1",
    });

    const prompt = await fetch(`${baseUrl}/agent/w1%3Ap1/prompt`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ text: "check status" }),
    });
    expect(prompt.status).toBe(200);
    expect(await jsonResponse(prompt)).toEqual({ ok: true });

    const keys = await fetch(`${baseUrl}/agent/w1%3Ap1/keys`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ keys: ["esc", "ctrl+c"] }),
    });
    expect(keys.status).toBe(200);
    expect(await jsonResponse(keys)).toEqual({ ok: true });

    expect(cli.calls).toEqual([
      [
        "pane",
        "read",
        "w1:p1",
        "--source",
        "recent-unwrapped",
        "--lines",
        "42",
        "--format",
        "ansi",
      ],
      ["agent", "prompt", "w1:p1", "check status"],
      ["agent", "send-keys", "w1:p1", "esc", "ctrl+c"],
    ]);
  });

  test("maps bad input, missing targets, and CLI failures to 400, 404, and 502", async () => {
    const { baseUrl } = startTestServer();

    const malformed = await fetch(`${baseUrl}/agent/pi/prompt`, {
      method: "POST",
      body: "{",
    });
    expect(malformed.status).toBe(400);

    const missing = await fetch(`${baseUrl}/pane/missing/output`);
    expect(missing.status).toBe(404);
    expect(await jsonResponse(missing)).toEqual({ ok: false, error: "Target not found" });

    const failed = await fetch(`${baseUrl}/pane/failure/output`);
    expect(failed.status).toBe(502);
    expect(await jsonResponse(failed)).toEqual({ ok: false, error: "Herdr command failed" });

    const unknownRoute = await fetch(`${baseUrl}/unknown`);
    expect(unknownRoute.status).toBe(404);
  });

  test("rejects oversized bodies, prompt text, key arrays, key values, and line counts", async () => {
    const { baseUrl, cli } = startTestServer();
    const requests = [
      fetch(`${baseUrl}/agent/pi/prompt`, {
        method: "POST",
        body: JSON.stringify({ text: "x".repeat(MAX_REQUEST_BODY_BYTES) }),
      }),
      fetch(`${baseUrl}/agent/pi/prompt`, {
        method: "POST",
        body: JSON.stringify({ text: "x".repeat(MAX_PROMPT_TEXT_LENGTH + 1) }),
      }),
      fetch(`${baseUrl}/agent/pi/keys`, {
        method: "POST",
        body: JSON.stringify({ keys: Array.from({ length: MAX_KEYS_COUNT + 1 }, () => "esc") }),
      }),
      fetch(`${baseUrl}/agent/pi/keys`, {
        method: "POST",
        body: JSON.stringify({ keys: ["x".repeat(MAX_KEY_LENGTH + 1)] }),
      }),
      fetch(`${baseUrl}/pane/w1%3Ap1/output?lines=not-a-number`),
      fetch(`${baseUrl}/pane/w1%3Ap1/output?lines=${MAX_OUTPUT_LINES + 1}`),
    ];

    for (const response of await Promise.all(requests)) {
      expect(response.status).toBe(400);
      expect(await jsonResponse(response)).toMatchObject({ ok: false });
    }
    expect(cli.calls).toHaveLength(0);
  });

  test("rejects flag-like pane IDs, targets, prompt text, and keys before invoking Herdr", async () => {
    const { baseUrl, cli } = startTestServer();
    const requests = [
      fetch(`${baseUrl}/pane/${encodeURIComponent("--help")}/output`),
      fetch(`${baseUrl}/agent/${encodeURIComponent("--help")}/prompt`, {
        method: "POST",
        body: JSON.stringify({ text: "safe" }),
      }),
      fetch(`${baseUrl}/agent/pi/prompt`, {
        method: "POST",
        body: JSON.stringify({ text: "--help" }),
      }),
      fetch(`${baseUrl}/agent/pi/keys`, {
        method: "POST",
        body: JSON.stringify({ keys: ["--help"] }),
      }),
    ];

    for (const response of await Promise.all(requests)) expect(response.status).toBe(400);
    expect(cli.calls).toHaveLength(0);
  });
});

describe("sidecar v1.1 HTTP integration", () => {
  test("creates a workspace and tab, and forwards raw pane text", async () => {
    const { baseUrl, cli, engine } = startTestServer();

    const workspace = await fetch(`${baseUrl}/workspace`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ label: "field-log" }),
    });
    expect(workspace.status).toBe(200);
    expect(await jsonResponse(workspace)).toEqual({ ok: true });

    const unlabeled = await fetch(`${baseUrl}/workspace`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({}),
    });
    expect(unlabeled.status).toBe(200);

    const tab = await fetch(`${baseUrl}/workspace/w1/tab`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ label: "server" }),
    });
    expect(tab.status).toBe(200);
    expect(await jsonResponse(tab)).toEqual({ ok: true });

    const input = await fetch(`${baseUrl}/pane/w1%3Ap1/input`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ text: "/model" }),
    });
    expect(input.status).toBe(200);
    expect(await jsonResponse(input)).toEqual({ ok: true });

    expect(cli.calls).toEqual([
      ["workspace", "create", "--label", "field-log"],
      ["workspace", "create"],
      ["tab", "create", "--workspace", "w1", "--label", "server"],
      ["pane", "send-text", "w1:p1", "/model"],
    ]);
    expect(engine.pollCalls).toEqual([true, true, true]);
  });

  test("returns route-specific 502 when workspace create succeeds but structure refresh fails", async () => {
    const { baseUrl, cli, engine } = startTestServer();
    engine.pollResult = false;

    const workspace = await fetch(`${baseUrl}/workspace`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({}),
    });
    expect(workspace.status).toBe(502);
    expect(await jsonResponse(workspace)).toEqual({
      ok: false,
      error: "Workspace was created, but state refresh failed; refresh before retrying",
    });
    expect(cli.calls).toEqual([["workspace", "create"]]);
    expect(engine.pollCalls).toEqual([true]);
  });

  test("rejects flag-like and overlong labels and input before invoking Herdr", async () => {
    const { baseUrl, cli } = startTestServer();
    const requests = [
      fetch(`${baseUrl}/workspace`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ label: "--help" }),
      }),
      fetch(`${baseUrl}/workspace`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ label: "x".repeat(MAX_LABEL_LENGTH + 1) }),
      }),
      fetch(`${baseUrl}/workspace/${encodeURIComponent("--help")}/tab`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({}),
      }),
      fetch(`${baseUrl}/workspace/w1/tab`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ label: "-inject" }),
      }),
      fetch(`${baseUrl}/pane/w1%3Ap1/input`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ text: "--flag" }),
      }),
      fetch(`${baseUrl}/pane/${encodeURIComponent("--help")}/input`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ text: "safe" }),
      }),
    ];

    for (const response of await Promise.all(requests)) expect(response.status).toBe(400);
    expect(cli.calls).toHaveLength(0);
  });
});

describe("sidecar v2 HTTP integration", () => {
  test("acknowledges an encoded paneId with no body, exact focus argv, and an agent poll", async () => {
    const { baseUrl, cli, engine } = startTestServer();

    const response = await fetch(`${baseUrl}/agent/w1%3Ap1/acknowledge`, { method: "POST" });
    expect(response.status).toBe(200);
    expect(await jsonResponse(response)).toEqual({ ok: true });
    expect(cli.calls).toEqual([["agent", "focus", "w1:p1"]]);
    expect(engine.pollCalls).toEqual([false]);
  });

  test("rejects encoded --help before any CLI or poll call", async () => {
    const { baseUrl, cli, engine } = startTestServer();

    const response = await fetch(`${baseUrl}/agent/${encodeURIComponent("--help")}/acknowledge`, {
      method: "POST",
    });
    expect(response.status).toBe(400);
    expect(cli.calls).toHaveLength(0);
    expect(engine.pollCalls).toHaveLength(0);
  });

  test("maps missing acknowledge targets to 404 without polling", async () => {
    const { baseUrl, cli, engine } = startTestServer();

    const response = await fetch(`${baseUrl}/agent/missing/acknowledge`, { method: "POST" });
    expect(response.status).toBe(404);
    expect(await jsonResponse(response)).toEqual({ ok: false, error: "Target not found" });
    expect(cli.calls).toEqual([["agent", "focus", "missing"]]);
    expect(engine.pollCalls).toHaveLength(0);
  });

  test("redacts acknowledge CLI failures as 502 without polling", async () => {
    const { baseUrl, cli, engine } = startTestServer();

    const response = await fetch(`${baseUrl}/agent/failure/acknowledge`, { method: "POST" });
    expect(response.status).toBe(502);
    const body = await jsonResponse(response);
    expect(body).toEqual({ ok: false, error: "Herdr command failed" });
    expect(JSON.stringify(body).includes("top-secret")).toBe(false);
    expect(cli.calls).toEqual([["agent", "focus", "failure"]]);
    expect(engine.pollCalls).toHaveLength(0);
  });

  test("returns partial-success 502 when focus succeeds but the agent poll fails", async () => {
    const { baseUrl, cli, engine } = startTestServer();
    engine.pollResult = false;

    const response = await fetch(`${baseUrl}/agent/w1%3Ap1/acknowledge`, { method: "POST" });
    expect(response.status).toBe(502);
    expect(await jsonResponse(response)).toEqual({
      ok: false,
      error: "Agent was acknowledged, but state refresh failed; refresh before retrying",
    });
    expect(cli.calls).toEqual([["agent", "focus", "w1:p1"]]);
    expect(engine.pollCalls).toEqual([false]);
  });
});

describe("sidecar WebSocket integration", () => {
  test("serializes reads, drops stale output, replaces watches, and cleans up on unwatch and close", async () => {
    const cli = new FakeCli();
    cli.deferPaneReads = true;
    const { baseUrl } = startTestServer(cli, 100);
    const first = await connectWebSocket(baseUrl);
    expect(first.messages[0]).toEqual({ type: "state", state: snapshot });

    send(first.socket, { type: "watch", paneId: "pane-a", lines: 5 });
    await waitUntil(() => cli.pendingReads[0]?.paneId === "pane-a", "pane-a read");
    send(first.socket, { type: "watch", paneId: "pane-b", lines: 6 });
    await Bun.sleep(20);
    expect(cli.activeReads).toBe(1);
    expect(cli.maxActiveReads).toBe(1);
    expect(cli.pendingReads).toHaveLength(1);

    cli.resolveNextRead("stale-a");
    await waitUntil(() => cli.pendingReads[0]?.paneId === "pane-b", "pane-b read");
    expect(first.messages.some((message) => message.paneId === "pane-a")).toBe(false);
    expect(cli.maxActiveReads).toBe(1);

    cli.resolveNextRead("fresh-b");
    await waitUntil(
      () => first.messages.some((message) => message.type === "output" && message.paneId === "pane-b"),
      "pane-b output",
    );
    const callsAfterWatch = cli.calls.length;
    send(first.socket, { type: "unwatch" });
    await Bun.sleep(140);
    expect(cli.calls).toHaveLength(callsAfterWatch);
    expect(cli.pendingReads).toHaveLength(0);

    const second = await connectWebSocket(baseUrl);
    send(second.socket, { type: "watch", paneId: "pane-c" });
    await waitUntil(() => cli.pendingReads[0]?.paneId === "pane-c", "pane-c read");
    cli.resolveNextRead("fresh-c");
    await waitUntil(
      () => second.messages.some((message) => message.type === "output" && message.paneId === "pane-c"),
      "pane-c output",
    );
    const callsBeforeClose = cli.calls.length;
    second.socket.close();
    await new Promise<void>((resolve) => {
      if (second.socket.readyState === WebSocket.CLOSED) resolve();
      else second.socket.addEventListener("close", () => resolve(), { once: true });
    });
    await Bun.sleep(140);
    expect(cli.calls).toHaveLength(callsBeforeClose);
    expect(cli.pendingReads).toHaveLength(0);
  });

  test("returns error frames for malformed, over-limit, and flag-like watch messages", async () => {
    const { baseUrl, cli } = startTestServer();
    const { socket, messages } = await connectWebSocket(baseUrl);

    socket.send("{");
    send(socket, { type: "watch", paneId: "w1:p1", lines: MAX_OUTPUT_LINES + 1 });
    send(socket, { type: "watch", paneId: "w1:p1", lines: true });
    send(socket, { type: "watch", paneId: "--help" });
    await waitUntil(
      () => messages.filter((message) => message.type === "error").length === 4,
      "four validation errors",
    );
    expect(cli.calls).toHaveLength(0);

    send(socket, { type: "watch", paneId: "failure" });
    await waitUntil(
      () => messages.some((message) => message.message === "Herdr command failed"),
      "redacted Herdr error",
    );
    expect(messages.find((message) => message.message === "Herdr command failed")).toBeDefined();
    expect(messages.some((message) => String(message.message).includes("top-secret"))).toBe(false);
    expect(cli.calls).toContainEqual(expect.arrayContaining(["pane", "read", "failure"]));
  });

  test("watch format ansi is passed through to pane read and output frames", async () => {
    const { baseUrl, cli } = startTestServer();
    const { socket, messages } = await connectWebSocket(baseUrl);
    send(socket, { type: "watch", paneId: "w1:p1", lines: 20, format: "ansi" });
    await waitUntil(
      () => messages.some((message) => message.type === "output" && message.format === "ansi"),
      "ansi output",
    );
    expect(cli.calls[0]).toEqual([
      "pane",
      "read",
      "w1:p1",
      "--source",
      "recent-unwrapped",
      "--lines",
      "20",
      "--format",
      "ansi",
    ]);
  });

  test("production watch interval is 250ms, serialized, and does not overlap in-flight reads", async () => {
    expect(DEFAULT_OUTPUT_INTERVAL_MS).toBe(250);

    const cli = new FakeCli();
    cli.deferPaneReads = true;
    const engine = new FakeEngine();
    const sidecar = startSidecar({
      engine: engine as unknown as StateEngine,
      cli,
      hosts: ["127.0.0.1"],
      port: 0,
      pingIntervalMs: 60_000,
    });
    running.push(sidecar);
    const baseUrl = `http://127.0.0.1:${sidecar.servers[0]!.port}`;
    const { socket } = await connectWebSocket(baseUrl);

    send(socket, { type: "watch", paneId: "pane-fast", lines: 5 });
    await waitUntil(() => cli.pendingReads[0]?.paneId === "pane-fast", "first production read");
    expect(cli.activeReads).toBe(1);

    await Bun.sleep(DEFAULT_OUTPUT_INTERVAL_MS + 80);
    expect(cli.pendingReads).toHaveLength(1);
    expect(cli.maxActiveReads).toBe(1);

    const t0 = Date.now();
    cli.resolveNextRead("tick-1");
    await waitUntil(() => cli.pendingReads[0]?.paneId === "pane-fast", "second production read");
    const elapsed = Date.now() - t0;
    expect(elapsed).toBeGreaterThanOrEqual(200);
    expect(elapsed).toBeLessThan(450);
    expect(cli.activeReads).toBe(1);
    expect(cli.maxActiveReads).toBe(1);
    cli.resolveNextRead("tick-2");
    await waitUntil(() => cli.activeReads === 0, "second production read completion");
    socket.close();
    await new Promise<void>((resolve) => {
      if (socket.readyState === WebSocket.CLOSED) resolve();
      else socket.addEventListener("close", () => resolve(), { once: true });
    });
  });
});

describe("binding validation", () => {
  test("validates Tailscale IPv4 addresses and refuses wildcard hosts before binding", () => {
    expect(isSafeTailscaleIpv4("100.64.0.1")).toBe(true);
    expect(isSafeTailscaleIpv4("999.64.0.1")).toBe(false);
    expect(isSafeTailscaleIpv4("0.0.0.0")).toBe(false);
    expect(isSafeTailscaleIpv4("255.255.255.255")).toBe(false);
    expect(isSafeTailscaleIpv4("224.0.0.1")).toBe(false);

    const cli = new FakeCli();
    const engine = new FakeEngine();
    expect(() =>
      startSidecar({
        engine: engine as unknown as StateEngine,
        cli,
        hosts: ["0.0.0.0"],
        port: 0,
      }),
    ).toThrow("Refusing to bind");
  });

  test("rejects wildcard aliases, multicast, class-E, and IPv6; accepts loopback and unicast IPv4", () => {
    const cli = new FakeCli();
    const engine = new FakeEngine();
    const rejected = ["::0", "000.000.000.000", "0.0.0.0", "240.0.0.1", "224.0.0.1", "255.255.255.255"];
    for (const host of rejected) {
      expect(isSafeTailscaleIpv4(host)).toBe(false);
      expect(() =>
        startSidecar({
          engine: engine as unknown as StateEngine,
          cli,
          hosts: [host],
          port: 0,
        }),
      ).toThrow("Refusing to bind");
    }

    expect(isSafeTailscaleIpv4("127.0.0.1")).toBe(true);
    expect(isSafeTailscaleIpv4("100.115.104.23")).toBe(true);

    const loopback = startSidecar({
      engine: engine as unknown as StateEngine,
      cli,
      hosts: ["127.0.0.1"],
      port: 0,
    });
    running.push(loopback);
    expect(loopback.servers.length).toBeGreaterThan(0);

    expect(() => {
      running.push(
        startSidecar({
          engine: engine as unknown as StateEngine,
          cli,
          hosts: ["100.115.104.23"],
          port: 0,
        }),
      );
    }).not.toThrow();
  });
});
