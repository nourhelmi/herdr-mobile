import SwiftUI

struct PaneView: View {
    @Environment(SessionController.self) private var session
    @Environment(\.dismiss) private var dismiss
    let pane: PaneSnapshot

    @State private var actionError: String?
    @State private var showClosePane = false
    @State private var isClosing = false

    private var live: PaneSnapshot {
        let tree = session.orderedWorkspaces.flatMap(\.tabs).flatMap(\.panes)
        return tree.first { $0.id == pane.id } ?? pane
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(HerdrInk.rule).frame(height: 1)
            TerminalOutputView(
                text: session.outputPaneId == live.id ? session.outputText : "",
                emptyMessage: "Watching \(live.id) — output pins to the tail."
            )
        }
        .background(HerdrInk.void)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(HerdrInk.void, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Close Pane…", role: .destructive) {
                        showClosePane = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(HerdrInk.paper)
                        .accessibilityLabel("Pane actions")
                }
            }
        }
        .confirmationDialog("Close Pane?", isPresented: $showClosePane, titleVisibility: .visible) {
            Button("Close Pane", role: .destructive) {
                let paneId = live.id
                Task { await closePane(id: paneId) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(CloseScopeCopy.paneMessage(title: title, paneId: live.id))
        }
        .onAppear { session.watch(paneId: live.id) }
        .onDisappear { session.unwatch() }
    }

    private var title: String {
        if let label = live.label, !label.isEmpty { return label }
        if !live.title.isEmpty { return live.title }
        return live.id
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let agent = live.agent {
                    StateBadge(state: agent.state)
                } else {
                    Text(live.isAgent ? "AGENT" : "PANE")
                        .font(HerdrType.meta)
                        .foregroundStyle(HerdrInk.mute)
                }
                Spacer()
                Text(live.id)
                    .font(HerdrType.meta)
                    .foregroundStyle(HerdrInk.mute)
                    .accessibilityLabel("Pane \(live.id)")
            }
            Text(title)
                .font(HerdrType.display)
                .foregroundStyle(HerdrInk.paper)
            if !live.cwd.isEmpty {
                Text(live.cwd)
                    .font(HerdrType.meta)
                    .foregroundStyle(HerdrInk.mute)
            }
            ErrorBanner(message: actionError ?? session.lastError)
        }
        .padding(12)
        .background(HerdrInk.panel)
    }

    private func closePane(id: String) async {
        guard !isClosing else { return }
        isClosing = true
        defer { isClosing = false }
        do {
            try await session.closePane(id: id)
            actionError = nil
            dismiss()
        } catch {
            actionError = error.localizedDescription
        }
    }
}
