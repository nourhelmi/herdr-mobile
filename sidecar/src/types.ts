export interface RawAgent {
  agent?: string;
  name?: string;
  agent_status?: string;
  pane_id: string;
  workspace_id: string;
  tab_id: string;
  cwd?: string;
  display_agent?: string | null;
  terminal_title_stripped?: string;
  focused?: boolean;
}

export interface RawWorkspace {
  workspace_id: string;
  label?: string;
  number: number;
  focused: boolean;
  agent_status?: string;
}

export interface RawTab {
  tab_id: string;
  workspace_id: string;
  label?: string;
  number: number;
  focused: boolean;
  agent_status?: string;
}

export interface RawPane {
  pane_id: string;
  workspace_id: string;
  tab_id: string;
  label?: string;
  terminal_title_stripped?: string;
  cwd?: string;
}

export interface AgentSnapshot {
  name: string;
  displayName: string | null;
  paneId: string;
  workspaceId: string;
  tabId: string;
  state: string;
  cwd: string;
  paneLabel: string | null;
}

export interface PaneSnapshot {
  id: string;
  label: string | null;
  title: string;
  cwd: string;
  isAgent: boolean;
  agent: AgentSnapshot | null;
}

export interface TabSnapshot {
  id: string;
  label: string;
  number: number;
  focused: boolean;
  agentStatus: string;
  panes: PaneSnapshot[];
}

export interface WorkspaceSnapshot {
  id: string;
  label: string;
  number: number;
  focused: boolean;
  agentStatus: string;
  tabs: TabSnapshot[];
}

export interface Snapshot {
  generatedAt: string;
  workspaces: WorkspaceSnapshot[];
  agents: AgentSnapshot[];
}
