import { parseDisplayAgent } from "./display";
import type {
  AgentSnapshot,
  RawAgent,
  RawPane,
  RawTab,
  RawWorkspace,
  Snapshot,
} from "./types";

export interface SnapshotInput {
  agents: RawAgent[];
  workspaces: RawWorkspace[];
  tabs: RawTab[];
  panes: RawPane[];
  generatedAt?: string;
}

export interface AgentTransition {
  paneId: string;
  from: string;
  to: string;
  agent: AgentSnapshot;
}

function state(value: string | undefined): string {
  return value ?? "unknown";
}

export function buildSnapshot(input: SnapshotInput): Snapshot {
  const panesById = new Map(input.panes.map((pane) => [pane.pane_id, pane]));
  const agents = input.agents.map<AgentSnapshot>((agent) => ({
    name: agent.agent ?? "unknown",
    displayName: agent.display_agent ?? null,
    display: parseDisplayAgent(agent.display_agent),
    paneId: agent.pane_id,
    workspaceId: agent.workspace_id,
    tabId: agent.tab_id,
    state: state(agent.agent_status),
    cwd: agent.cwd ?? "",
    paneLabel: panesById.get(agent.pane_id)?.label ?? null,
  }));
  const agentsByPane = new Map(agents.map((agent) => [agent.paneId, agent]));

  return {
    generatedAt: input.generatedAt ?? new Date().toISOString(),
    workspaces: input.workspaces.map((workspace) => ({
      id: workspace.workspace_id,
      label: workspace.label ?? String(workspace.number),
      number: workspace.number,
      focused: workspace.focused,
      agentStatus: state(workspace.agent_status),
      tabs: input.tabs
        .filter((tab) => tab.workspace_id === workspace.workspace_id)
        .map((tab) => ({
          id: tab.tab_id,
          label: tab.label ?? String(tab.number),
          number: tab.number,
          focused: tab.focused,
          agentStatus: state(tab.agent_status),
          panes: input.panes
            .filter((pane) => pane.tab_id === tab.tab_id)
            .map((pane) => {
              const agent = agentsByPane.get(pane.pane_id) ?? null;
              return {
                id: pane.pane_id,
                label: pane.label ?? null,
                title: pane.terminal_title_stripped ?? "",
                cwd: pane.cwd ?? "",
                isAgent: agent !== null,
                agent,
              };
            }),
        })),
    })),
    agents,
  };
}

function snapshotContents(snapshot: Snapshot): string {
  return JSON.stringify({ workspaces: snapshot.workspaces, agents: snapshot.agents });
}

export function diffSnapshots(previous: Snapshot | null, next: Snapshot): {
  changed: boolean;
  transitions: AgentTransition[];
} {
  if (previous === null) return { changed: true, transitions: [] };

  const previousAgents = new Map(previous.agents.map((agent) => [agent.paneId, agent]));
  const transitions = next.agents.flatMap((agent) => {
    const before = previousAgents.get(agent.paneId);
    return before && before.state !== agent.state
      ? [{ paneId: agent.paneId, from: before.state, to: agent.state, agent }]
      : [];
  });

  return {
    changed: snapshotContents(previous) !== snapshotContents(next),
    transitions,
  };
}

export function agentSetAndStateSignature(agents: RawAgent[]): string {
  return agents
    .map((agent) => `${agent.pane_id}\u0000${state(agent.agent_status)}`)
    .sort()
    .join("\u0001");
}
