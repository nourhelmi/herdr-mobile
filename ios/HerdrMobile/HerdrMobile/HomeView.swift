import SwiftUI

struct HomeView: View {
    @Environment(SessionController.self) private var session

    var body: some View {
        List {
            if let message = session.lastError, session.snapshot == nil {
                Section {
                    emptyBlock(
                        title: "No lock on the sidecar",
                        detail: message,
                        systemImage: "antenna.radiowaves.left.and.right.slash"
                    )
                }
            } else if session.snapshot == nil {
                Section {
                    emptyBlock(
                        title: session.phase == .offline ? "Sidecar is dark" : "Pulling the tree",
                        detail: session.phase == .offline
                            ? "Set the sidecar URL in Settings, then pull to refresh."
                            : "Waiting on the first state frame.",
                        systemImage: "dot.radiowaves.left.and.right"
                    )
                }
            } else {
                agentsSection
                workspaceSection
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(HerdrInk.void)
        .refreshable { await session.refresh() }
        .navigationTitle("Herdr")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(HerdrInk.void, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ConnectionIndicator(phase: session.phase, herdrOK: session.herdrOK)
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(HerdrInk.paper)
                        .accessibilityLabel("Settings")
                }
            }
        }
    }

    @ViewBuilder
    private var agentsSection: some View {
        let agents = session.rankedAgents
        Section {
            if agents.isEmpty {
                emptyBlock(
                    title: "No agents on the floor",
                    detail: "The sidecar is live, but herdr agent list is empty.",
                    systemImage: "circle.dotted"
                )
            } else {
                ForEach(agents) { agent in
                    NavigationLink {
                        AgentDetailView(agent: agent)
                    } label: {
                        agentRow(agent)
                    }
                    .listRowBackground(HerdrInk.panel)
                    .listRowSeparatorTint(HerdrInk.rule)
                }
            }
        } header: {
            sectionLabel("Agents · blocked first")
        }
    }

    @ViewBuilder
    private var workspaceSection: some View {
        let workspaces = session.orderedWorkspaces
        Section {
            if workspaces.isEmpty {
                emptyBlock(
                    title: "No workspaces",
                    detail: "Structure poll returned an empty tree.",
                    systemImage: "square.dashed"
                )
            } else {
                ForEach(workspaces) { workspace in
                    DisclosureGroup {
                        ForEach(workspace.tabs.sorted { $0.number < $1.number }) { tab in
                            DisclosureGroup {
                                ForEach(tab.panes) { pane in
                                    NavigationLink {
                                        PaneView(pane: pane)
                                    } label: {
                                        paneRow(pane)
                                    }
                                    .listRowBackground(HerdrInk.inset)
                                }
                            } label: {
                                tabRow(tab)
                            }
                            .listRowBackground(HerdrInk.panel)
                        }
                    } label: {
                        workspaceRow(workspace)
                    }
                    .listRowBackground(HerdrInk.panel)
                    .listRowSeparatorTint(HerdrInk.rule)
                }
            }
        } header: {
            sectionLabel("Workspaces")
        }
    }

    private func agentRow(_ agent: AgentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                StateBadge(state: agent.state)
                Spacer()
                Text(agent.paneId)
                    .font(HerdrType.meta)
                    .foregroundStyle(HerdrInk.mute)
            }
            Text(agent.displayTitle)
                .font(HerdrType.body)
                .foregroundStyle(HerdrInk.paper)
                .lineLimit(2)
            if !agent.cwd.isEmpty {
                Text(agent.cwd)
                    .font(HerdrType.meta)
                    .foregroundStyle(HerdrInk.mute)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Agent \(agent.displayTitle), state \(AgentState.label(agent.state)), pane \(agent.paneId)")
    }

    private func workspaceRow(_ workspace: WorkspaceSnapshot) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(workspace.label)
                    .font(HerdrType.body)
                    .foregroundStyle(HerdrInk.paper)
                Text("w\(workspace.number) · \(workspace.tabs.count) tabs")
                    .font(HerdrType.meta)
                    .foregroundStyle(HerdrInk.mute)
            }
            Spacer()
            if workspace.focused {
                Text("FOCUS")
                    .font(HerdrType.meta)
                    .foregroundStyle(HerdrInk.phosphor)
            }
            StateBadge(state: workspace.agentStatus)
        }
        .accessibilityLabel("Workspace \(workspace.label), state \(AgentState.label(workspace.agentStatus))")
    }

    private func tabRow(_ tab: TabSnapshot) -> some View {
        HStack {
            Text(tab.label)
                .font(HerdrType.body)
                .foregroundStyle(HerdrInk.paper)
            Spacer()
            if tab.focused {
                Text("FOCUS")
                    .font(HerdrType.meta)
                    .foregroundStyle(HerdrInk.phosphor)
            }
            StateBadge(state: tab.agentStatus)
        }
        .accessibilityLabel("Tab \(tab.label), state \(AgentState.label(tab.agentStatus))")
    }

    private func paneRow(_ pane: PaneSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(paneTitle(pane))
                    .font(HerdrType.body)
                    .foregroundStyle(HerdrInk.paper)
                Spacer()
                if pane.isAgent {
                    Text("AGENT")
                        .font(HerdrType.meta)
                        .foregroundStyle(HerdrInk.phosphor)
                }
            }
            Text(pane.id)
                .font(HerdrType.meta)
                .foregroundStyle(HerdrInk.mute)
        }
        .accessibilityLabel("Pane \(paneTitle(pane))\(pane.isAgent ? ", agent" : "")")
    }

    private func paneTitle(_ pane: PaneSnapshot) -> String {
        if let label = pane.label, !label.isEmpty { return label }
        if !pane.title.isEmpty { return pane.title }
        return pane.id
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(HerdrType.section)
            .foregroundStyle(HerdrInk.mute)
            .textCase(.uppercase)
            .padding(.top, 8)
    }

    private func emptyBlock(title: String, detail: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(HerdrInk.phosphor)
                .accessibilityHidden(true)
            Text(title)
                .font(HerdrType.display)
                .foregroundStyle(HerdrInk.paper)
            Text(detail)
                .font(HerdrType.body)
                .foregroundStyle(HerdrInk.mute)
        }
        .padding(.vertical, 12)
        .listRowBackground(HerdrInk.panel)
        .accessibilityElement(children: .combine)
    }
}
