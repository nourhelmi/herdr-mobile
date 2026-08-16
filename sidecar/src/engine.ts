import { assertSafePositional, type HerdrCli } from "./cli";
import type { NotificationWatcher } from "./notifier";
import { agentSetAndStateSignature, buildSnapshot, diffSnapshots } from "./snapshot";
import type { RawAgent, RawPane, RawTab, RawWorkspace, Snapshot } from "./types";

type SnapshotListener = (snapshot: Snapshot) => void;

export class StateEngine {
  private agents: RawAgent[] = [];
  private workspaces: RawWorkspace[] = [];
  private tabs: RawTab[] = [];
  private panes: RawPane[] = [];
  private signature = "";
  private structurePolledAt = 0;
  private current: Snapshot | null = null;
  private queue: Promise<void> = Promise.resolve();
  private timers: Array<ReturnType<typeof setInterval>> = [];
  private listeners = new Set<SnapshotListener>();

  herdrOk = false;

  constructor(
    private readonly cli: HerdrCli,
    private readonly notifications: NotificationWatcher,
    private readonly agentIntervalMs = 3_000,
    private readonly structureIntervalMs = 10_000,
  ) {}

  get snapshot(): Snapshot {
    if (!this.current) throw new Error("State engine has not completed its initial poll");
    return this.current;
  }

  subscribe(listener: SnapshotListener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  async start(): Promise<void> {
    await this.poll(true);
    if (!this.current) throw new Error("Initial Herdr state poll failed");
    this.timers.push(setInterval(() => void this.poll(false), this.agentIntervalMs));
    this.timers.push(setInterval(() => void this.poll(true), this.structureIntervalMs));
  }

  stop(): void {
    for (const timer of this.timers) clearInterval(timer);
    this.timers = [];
  }

  poll(forceStructure: boolean): Promise<void> {
    const work = async () => {
      try {
        const result = await this.cli.json<{ agents: RawAgent[] }>(["agent", "list"]);
        const nextAgents = result.agents ?? [];
        const nextSignature = agentSetAndStateSignature(nextAgents);
        const structureDue = Date.now() - this.structurePolledAt >= this.structureIntervalMs;

        if (forceStructure || structureDue || nextSignature !== this.signature) {
          await this.refreshStructure();
        }

        this.agents = nextAgents;
        this.signature = nextSignature;
        const next = buildSnapshot({
          agents: this.agents,
          workspaces: this.workspaces,
          tabs: this.tabs,
          panes: this.panes,
        });
        const diff = diffSnapshots(this.current, next);
        await this.notifications.process(next.agents);
        this.herdrOk = true;

        if (diff.changed) {
          this.current = next;
          for (const listener of this.listeners) listener(next);
        }
      } catch (error) {
        this.herdrOk = false;
        console.error("Herdr state poll failed:", error);
      }
    };

    this.queue = this.queue.then(work, work);
    return this.queue;
  }

  private async refreshStructure(): Promise<void> {
    const [workspaceResult, tabResult] = await Promise.all([
      this.cli.json<{ workspaces: RawWorkspace[] }>(["workspace", "list"]),
      this.cli.json<{ tabs: RawTab[] }>(["tab", "list"]),
    ]);
    const workspaces = workspaceResult.workspaces ?? [];
    const paneResults = await Promise.all(
      workspaces.map(async (workspace) => {
        // Flag-like IDs from CLI output must not become argv; skip that workspace and keep polling.
        try {
          assertSafePositional(workspace.workspace_id, "workspace_id");
        } catch (error) {
          console.error("Skipping workspace with unsafe workspace_id:", workspace.workspace_id, error);
          return { panes: [] as RawPane[] };
        }
        return this.cli.json<{ panes: RawPane[] }>(["pane", "list", "--workspace", workspace.workspace_id]);
      }),
    );

    this.workspaces = workspaces;
    this.tabs = tabResult.tabs ?? [];
    this.panes = paneResults.flatMap((result) => result.panes ?? []);
    this.structurePolledAt = Date.now();
  }
}
