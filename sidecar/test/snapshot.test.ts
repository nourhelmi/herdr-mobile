import { describe, expect, test } from "bun:test";
import { resolve } from "node:path";
import {
  agentSetAndStateSignature,
  buildSnapshot,
  diffSnapshots,
} from "../src/snapshot";
import type { RawAgent, RawPane, RawTab, RawWorkspace } from "../src/types";

async function fixture<T>(name: string): Promise<T> {
  return Bun.file(resolve(import.meta.dir, "fixtures", name)).json() as Promise<T>;
}

async function fixtureInput() {
  const [agentEnvelope, workspaceEnvelope, tabEnvelope, paneFixture] = await Promise.all([
    fixture<{ result: { agents: RawAgent[] } }>("agents.json"),
    fixture<{ result: { workspaces: RawWorkspace[] } }>("workspaces.json"),
    fixture<{ result: { tabs: RawTab[] } }>("tabs.json"),
    fixture<{ result: { panes: RawPane[] } }>("panes.json"),
  ]);
  return {
    agents: agentEnvelope.result.agents,
    workspaces: workspaceEnvelope.result.workspaces,
    tabs: tabEnvelope.result.tabs,
    panes: paneFixture.result.panes,
  };
}

describe("buildSnapshot", () => {
  test("builds the frozen workspace tree from real Herdr fixtures", async () => {
    const input = await fixtureInput();
    const snapshot = buildSnapshot({ ...input, generatedAt: "2026-08-16T12:00:00.000Z" });

    expect(snapshot.generatedAt).toBe("2026-08-16T12:00:00.000Z");
    expect(snapshot.workspaces).toHaveLength(input.workspaces.length);
    expect(snapshot.agents).toHaveLength(input.agents.length);
    expect(snapshot.workspaces.flatMap((workspace) => workspace.tabs)).toHaveLength(input.tabs.length);
    expect(
      snapshot.workspaces.flatMap((workspace) => workspace.tabs.flatMap((tab) => tab.panes)),
    ).toHaveLength(input.panes.length);

    const labeledAgentPane = input.panes.find((pane) => pane.label && pane.pane_id === "w1:pDF");
    expect(labeledAgentPane).toBeDefined();
    const agent = snapshot.agents.find((candidate) => candidate.paneId === labeledAgentPane!.pane_id);
    expect(agent).toMatchObject({
      name: "pi",
      paneId: "w1:pDF",
      paneLabel: labeledAgentPane!.label,
      display: {
        model: "claude-fable-5",
        repo: "ai-tutor",
        branch: "main",
        cost: "$0.00",
      },
    });
    expect(agent!.display.text.includes("\uE0B0")).toBe(false);
    expect(agent!.display.text.includes("claude-fable-5")).toBe(true);
    const embedded = snapshot.workspaces
      .flatMap((workspace) => workspace.tabs)
      .flatMap((tab) => tab.panes)
      .find((pane) => pane.id === agent!.paneId);
    expect(embedded).toMatchObject({ isAgent: true, agent });
  });
});

describe("diffSnapshots", () => {
  test("ignores generatedAt-only changes and reports pane-keyed state transitions", async () => {
    const input = await fixtureInput();
    const previous = buildSnapshot({ ...input, generatedAt: "2026-08-16T12:00:00.000Z" });
    const timestampOnly = buildSnapshot({ ...input, generatedAt: "2026-08-16T12:01:00.000Z" });
    expect(diffSnapshots(previous, timestampOnly)).toEqual({ changed: false, transitions: [] });

    const changedAgents = input.agents.map((agent, index) =>
      index === 0 ? { ...agent, agent_status: "blocked" } : agent,
    );
    const changed = buildSnapshot({ ...input, agents: changedAgents });
    const diff = diffSnapshots(previous, changed);
    expect(diff.changed).toBe(true);
    expect(diff.transitions).toEqual([
      expect.objectContaining({
        paneId: input.agents[0]!.pane_id,
        from: input.agents[0]!.agent_status,
        to: "blocked",
      }),
    ]);
  });

  test("agent-set signature is stable across CLI ordering", async () => {
    const { agents } = await fixtureInput();
    expect(agentSetAndStateSignature(agents)).toBe(agentSetAndStateSignature([...agents].reverse()));
  });
});
