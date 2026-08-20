import SwiftUI

struct HomeView: View {
    @Environment(SessionController.self) private var session
    @State private var showNewWorkspace = false
    @State private var workspaceLabel = ""
    @State private var showNewTab = false
    @State private var tabWorkspace: WorkspaceSnapshot?
    @State private var tabLabel = ""
    @State private var createError: String?
    @State private var pendingClose: PendingClose?
    @State private var closeError: String?
    @State private var isClosing = false

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
                noticeSection
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
        .alert("New workspace", isPresented: $showNewWorkspace) {
            TextField("Label (optional)", text: $workspaceLabel)
            Button("Create") { Task { await createWorkspace() } }
            Button("Cancel", role: .cancel) { workspaceLabel = "" }
        } message: {
            Text("128 characters max. Labels may not start with -.")
        }
        .alert("New tab", isPresented: $showNewTab) {
            TextField("Label (optional)", text: $tabLabel)
            Button("Create") { Task { await createTab() } }
            Button("Cancel", role: .cancel) {
                tabLabel = ""
                tabWorkspace = nil
            }
        } message: {
            Text(tabWorkspace.map { "In \($0.label). 128 characters max." } ?? "128 characters max.")
        }
        .alert("Create failed", isPresented: Binding(
            get: { createError != nil },
            set: { if !$0 { createError = nil } }
        )) {
            Button("OK", role: .cancel) { createError = nil }
        } message: {
            Text(createError ?? "")
        }
        .alert("Close failed", isPresented: Binding(
            get: { closeError != nil },
            set: { if !$0 { closeError = nil } }
        )) {
            Button("OK", role: .cancel) { closeError = nil }
        } message: {
            Text(closeError ?? "")
        }
        .confirmationDialog(
            pendingCloseTitle,
            isPresented: Binding(
                get: { pendingClose != nil },
                set: { if !$0 { pendingClose = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(pendingCloseConfirmTitle, role: .destructive) {
                let pending = pendingClose
                pendingClose = nil
                Task { await confirmClose(pending) }
            }
            Button("Cancel", role: .cancel) { pendingClose = nil }
        } message: {
            Text(pendingCloseMessage)
        }
    }

    @ViewBuilder
    private var noticeSection: some View {
        if let notice = session.notice, !notice.isEmpty {
            Section {
                NoticeBanner(message: notice) {
                    session.clearNotice()
                }
                .listRowBackground(HerdrInk.panel)
                .listRowSeparatorTint(HerdrInk.rule)
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
                        PaneDetailView(paneId: agent.paneId, fallback: fallbackPane(for: agent))
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
                                        paneDestination(pane)
                                    } label: {
                                        paneRow(pane)
                                    }
                                    .listRowBackground(HerdrInk.inset)
                                    .closeActions("Close Pane…") {
                                        pendingClose = .pane(pane)
                                    }
                                }
                            } label: {
                                tabRow(tab)
                            }
                            .listRowBackground(HerdrInk.panel)
                            .closeActions("Close Tab…") {
                                pendingClose = .tab(tab)
                            }
                        }
                        Button {
                            tabWorkspace = workspace
                            tabLabel = ""
                            showNewTab = true
                        } label: {
                            Text("+ tab")
                                .font(HerdrType.meta)
                                .foregroundStyle(HerdrInk.phosphor)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .listRowBackground(HerdrInk.inset)
                        .accessibilityLabel("Create tab in \(workspace.label)")
                    } label: {
                        workspaceRow(workspace)
                    }
                    .listRowBackground(HerdrInk.panel)
                    .listRowSeparatorTint(HerdrInk.rule)
                    .closeActions("Close Workspace…") {
                        pendingClose = .workspace(workspace)
                    }
                }
            }
        } header: {
            HStack {
                sectionLabel("Workspaces")
                Spacer()
                Button("NEW") {
                    workspaceLabel = ""
                    showNewWorkspace = true
                }
                .font(HerdrType.meta)
                .foregroundStyle(HerdrInk.phosphor)
                .accessibilityLabel("Create workspace")
            }
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
                if pane.agent != nil {
                    Text("AGENT")
                        .font(HerdrType.meta)
                        .foregroundStyle(HerdrInk.phosphor)
                }
            }
            Text(pane.id)
                .font(HerdrType.meta)
                .foregroundStyle(HerdrInk.mute)
        }
        .accessibilityLabel("Pane \(paneTitle(pane))\(pane.agent != nil ? ", agent" : "")")
    }

    /// One destination for every pane row: PaneDetailView re-renders live as the
    /// authoritative snapshot's `agent` membership for this pane changes.
    private func paneDestination(_ pane: PaneSnapshot) -> some View {
        PaneDetailView(paneId: pane.id, fallback: pane)
    }

    /// Synthesized only as a pre-first-render fallback; PaneDetailView looks up the
    /// live pane by id on every render once the snapshot is available.
    private func fallbackPane(for agent: AgentSnapshot) -> PaneSnapshot {
        PaneSnapshot(
            id: agent.paneId,
            label: agent.paneLabel,
            title: "",
            cwd: agent.cwd,
            isAgent: true,
            agent: agent
        )
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

    private func createWorkspace() async {
        do {
            let label = try validatedLabel(workspaceLabel)
            try await session.createWorkspace(label: label)
            workspaceLabel = ""
        } catch {
            createError = error.localizedDescription
        }
    }

    private func createTab() async {
        guard let workspace = tabWorkspace else { return }
        do {
            let label = try validatedLabel(tabLabel)
            try await session.createTab(workspaceId: workspace.id, label: label)
            tabLabel = ""
            tabWorkspace = nil
        } catch {
            createError = error.localizedDescription
        }
    }

    private func validatedLabel(_ raw: String) throws -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.count > 128 {
            throw HerdrClientError(message: "label must not exceed 128 characters")
        }
        if trimmed.hasPrefix("-") {
            throw HerdrClientError(message: "label must not start with '-'")
        }
        return trimmed
    }
}

private enum PendingClose: Identifiable {
    case pane(PaneSnapshot)
    case tab(TabSnapshot)
    case workspace(WorkspaceSnapshot)

    var id: String {
        switch self {
        case .pane(let pane): return "pane:\(pane.id)"
        case .tab(let tab): return "tab:\(tab.id)"
        case .workspace(let workspace): return "workspace:\(workspace.id)"
        }
    }
}

private extension HomeView {
    var pendingCloseTitle: String {
        switch pendingClose {
        case .pane: return "Close Pane?"
        case .tab: return "Close Tab?"
        case .workspace: return "Close Workspace?"
        case nil: return "Close?"
        }
    }

    var pendingCloseConfirmTitle: String {
        switch pendingClose {
        case .pane: return "Close Pane"
        case .tab: return "Close Tab"
        case .workspace: return "Close Workspace"
        case nil: return "Close"
        }
    }

    var pendingCloseMessage: String {
        switch pendingClose {
        case .pane(let pane):
            return CloseScopeCopy.paneMessage(title: paneTitle(pane), paneId: pane.id)
        case .tab(let tab):
            return CloseScopeCopy.tabMessage(name: tab.label, paneCount: tab.panes.count)
        case .workspace(let workspace):
            let panes = workspace.tabs.reduce(0) { $0 + $1.panes.count }
            return CloseScopeCopy.workspaceMessage(
                name: workspace.label,
                tabCount: workspace.tabs.count,
                paneCount: panes
            )
        case nil:
            return ""
        }
    }

    func confirmClose(_ pending: PendingClose?) async {
        guard let pending, !isClosing else { return }
        isClosing = true
        defer { isClosing = false }
        do {
            switch pending {
            case .pane(let pane):
                try await session.closePane(id: pane.id)
            case .tab(let tab):
                try await session.closeTab(id: tab.id)
            case .workspace(let workspace):
                try await session.closeWorkspace(id: workspace.id)
            }
            closeError = nil
        } catch {
            closeError = error.localizedDescription
        }
    }
}

private extension View {
    /// Swipe and context menu both stage a confirm; they never close unconfirmed.
    func closeActions(_ title: String, stage: @escaping () -> Void) -> some View {
        contextMenu {
            Button(title, role: .destructive, action: stage)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(title, role: .destructive, action: stage)
        }
    }
}
