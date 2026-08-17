import { describe, expect, test } from "bun:test";
import type { HerdrCli } from "../src/cli";
import { StateEngine } from "../src/engine";
import type { NotificationWatcher } from "../src/notifier";
import type { RawPane, RawTab, RawWorkspace } from "../src/types";

class RecordingCli implements HerdrCli {
  readonly calls: string[][] = [];
  failJson = false;

  constructor(
    private readonly workspaces: RawWorkspace[],
    private readonly panesByWorkspace: Record<string, RawPane[]> = {},
  ) {}

  async json<T>(args: string[]): Promise<T> {
    this.calls.push([...args]);
    if (this.failJson) throw new Error("cli down");
    if (args[0] === "agent" && args[1] === "list") {
      return { agents: [] } as T;
    }
    if (args[0] === "workspace" && args[1] === "list") {
      return { workspaces: this.workspaces } as T;
    }
    if (args[0] === "tab" && args[1] === "list") {
      return { tabs: [] as RawTab[] } as T;
    }
    if (args[0] === "pane" && args[1] === "list") {
      const workspaceId = args[3];
      return { panes: this.panesByWorkspace[workspaceId ?? ""] ?? [] } as T;
    }
    throw new Error(`unexpected herdr argv: ${args.join(" ")}`);
  }

  async text(args: string[]): Promise<string> {
    this.calls.push([...args]);
    throw new Error(`unexpected herdr text argv: ${args.join(" ")}`);
  }
}

const notifications = { process: async () => undefined } as unknown as NotificationWatcher;

describe("StateEngine positional validation", () => {
  test("skips a flag-like workspace_id without spawning and continues polling others", async () => {
    const cli = new RecordingCli(
      [
        { workspace_id: "--inject", number: 1, focused: false },
        { workspace_id: "ws-safe", number: 2, focused: true },
      ],
      {
        "ws-safe": [{ pane_id: "ws-safe:p1", workspace_id: "ws-safe", tab_id: "t1" }],
      },
    );
    const engine = new StateEngine(cli, notifications, 60_000, 60_000);

    expect(await engine.poll(true)).toBe(true);

    expect(engine.herdrOk).toBe(true);
    expect(cli.calls).toContainEqual(["agent", "list"]);
    expect(cli.calls).toContainEqual(["workspace", "list"]);
    expect(cli.calls).toContainEqual(["tab", "list"]);
    expect(cli.calls).toContainEqual(["pane", "list", "--workspace", "ws-safe"]);
    expect(cli.calls.some((args) => args.includes("--inject"))).toBe(false);
    expect(engine.snapshot.workspaces.some((workspace) => workspace.id === "ws-safe")).toBe(true);
  });

  test("successful poll resolves true; failing poll resolves false and keeps the prior snapshot", async () => {
    const cli = new RecordingCli(
      [{ workspace_id: "ws-safe", number: 1, focused: true }],
      { "ws-safe": [{ pane_id: "ws-safe:p1", workspace_id: "ws-safe", tab_id: "t1" }] },
    );
    const engine = new StateEngine(cli, notifications, 60_000, 60_000);

    expect(await engine.poll(true)).toBe(true);
    const prior = engine.snapshot;

    cli.failJson = true;
    expect(await engine.poll(true)).toBe(false);
    expect(engine.herdrOk).toBe(false);
    expect(engine.snapshot).toBe(prior);
  });
});
