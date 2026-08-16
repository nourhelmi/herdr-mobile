import { mkdir, rename } from "node:fs/promises";
import { dirname } from "node:path";
import type { AgentSnapshot } from "./types";

export interface NotificationState {
  states: Record<string, string>;
  notifiedAt: Record<string, number>;
}

export interface NotificationDecision {
  agent: AgentSnapshot;
  state: "blocked" | "done";
}

export class NotificationTracker {
  constructor(
    readonly data: NotificationState = { states: {}, notifiedAt: {} },
    private readonly debounceMs = 60_000,
  ) {}

  observe(agents: AgentSnapshot[], now = Date.now()): NotificationDecision[] {
    const decisions: NotificationDecision[] = [];

    for (const agent of agents) {
      const previous = this.data.states[agent.paneId];
      this.data.states[agent.paneId] = agent.state;
      if (previous === undefined || previous === agent.state) continue;
      if (agent.state !== "blocked" && agent.state !== "done") continue;

      const key = `${agent.paneId}:${agent.state}`;
      const lastNotifiedAt = this.data.notifiedAt[key];
      if (lastNotifiedAt !== undefined && now - lastNotifiedAt < this.debounceMs) continue;
      this.data.notifiedAt[key] = now;
      decisions.push({ agent, state: agent.state });
    }

    return decisions;
  }
}

async function writeJsonAtomic(path: string, value: unknown): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const temporary = `${path}.${process.pid}.tmp`;
  await Bun.write(temporary, `${JSON.stringify(value, null, 2)}\n`);
  await rename(temporary, path);
}

export async function loadNotificationTracker(path: string): Promise<NotificationTracker> {
  try {
    const data = (await Bun.file(path).json()) as NotificationState;
    return new NotificationTracker({
      states: data.states ?? {},
      notifiedAt: data.notifiedAt ?? {},
    });
  } catch {
    return new NotificationTracker();
  }
}

export async function loadOrCreateTopic(configPath: string): Promise<string> {
  try {
    const config = (await Bun.file(configPath).json()) as { ntfyTopic?: string };
    if (config.ntfyTopic) return config.ntfyTopic;
  } catch {
    // Create the config below.
  }

  const topic = `${crypto.randomUUID().replaceAll("-", "")}${crypto.randomUUID().replaceAll("-", "")}`;
  await writeJsonAtomic(configPath, { ntfyTopic: topic });
  return topic;
}

function truncateUtf8(value: string, maxBytes: number): string {
  const bytes = new TextEncoder().encode(value);
  if (bytes.byteLength <= maxBytes) return value;
  return new TextDecoder().decode(bytes.slice(0, maxBytes - 3)).replace(/\uFFFD$/, "") + "...";
}

function recentLines(text: string, count: number): string {
  return text.trimEnd().split("\n").slice(-count).join("\n");
}

export class NotificationWatcher {
  constructor(
    private readonly tracker: NotificationTracker,
    private readonly statePath: string,
    private readonly topic: string,
    private readonly readPane: (paneId: string, lines: number) => Promise<string>,
    private readonly publish: (topic: string, message: string) => Promise<void> = publishNtfy,
  ) {}

  async process(agents: AgentSnapshot[]): Promise<void> {
    const decisions = this.tracker.observe(agents);
    await writeJsonAtomic(this.statePath, this.tracker.data);

    for (const decision of decisions) {
      try {
        const output = await this.readPane(decision.agent.paneId, 15);
        const message = truncateUtf8(
          `${decision.agent.name}: ${decision.state}\n\n${recentLines(output, 15)}`,
          3_900,
        );
        await this.publish(this.topic, message);
      } catch (error) {
        console.error(`Notification failed for ${decision.agent.paneId}:`, error);
      }
    }
  }
}

export async function publishNtfy(topic: string, message: string): Promise<void> {
  const response = await fetch(`https://ntfy.sh/${encodeURIComponent(topic)}`, {
    method: "POST",
    headers: { Title: "Herdr agent update" },
    body: message,
  });
  if (!response.ok) {
    throw new Error(`ntfy returned HTTP ${response.status}: ${await response.text()}`);
  }
}
