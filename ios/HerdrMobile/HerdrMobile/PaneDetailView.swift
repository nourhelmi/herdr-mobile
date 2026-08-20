import SwiftUI

/// Live authoritative switch between the bare-terminal and agent detail screens.
/// Routes only on `pane.agent != nil` from the current snapshot — never on title,
/// cwd, status strings, or terminal contents — so an open detail screen re-renders
/// into the other mode the instant Pi starts or exits in this pane, no reopen needed.
struct PaneDetailView: View {
    @Environment(SessionController.self) private var session
    let paneId: String
    let fallback: PaneSnapshot

    private var livePane: PaneSnapshot? {
        session.orderedWorkspaces
            .flatMap(\.tabs)
            .flatMap(\.panes)
            .first { $0.id == paneId }
    }

    var body: some View {
        let pane = livePane ?? fallback
        Group {
            if let agent = pane.agent {
                AgentDetailView(agent: agent)
            } else {
                PaneView(pane: pane)
            }
        }
        // Own the watch above both branches: a disappearing child must not race
        // an appearing child and leave a live role transition unsubscribed.
        .onAppear { session.watch(paneId: paneId) }
        .onDisappear { session.unwatch() }
    }
}
