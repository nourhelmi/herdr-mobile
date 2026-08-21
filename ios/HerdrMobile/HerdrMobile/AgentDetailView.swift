import SwiftUI
import UIKit

struct AgentDetailView: View {
    @Environment(SessionController.self) private var session
    @Environment(\.dismiss) private var dismiss
    let agent: AgentSnapshot

    @State private var input = TerminalInputController()
    @State private var actionError: String?
    @State private var isAcknowledging = false
    @State private var acknowledgementMessage: String?
    @State private var showClosePane = false
    @State private var isClosing = false
    @State private var showHistory = false

    private var live: AgentSnapshot {
        session.snapshot?.agents.first { $0.paneId == agent.paneId } ?? agent
    }

    var body: some View {
        @Bindable var input = input
        return VStack(spacing: 0) {
            if showsRibbon {
                AgentMetadataRibbon(agent: live) {
                    if live.state == "done" {
                        compactAcknowledge
                    }
                }
                Rectangle().fill(HerdrInk.rule).frame(height: 1)
            } else if live.state == "done" {
                HStack {
                    Spacer(minLength: 0)
                    compactAcknowledge
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(HerdrInk.panel)
                Rectangle().fill(HerdrInk.rule).frame(height: 1)
            }
            TerminalOutputView(
                text: session.outputPaneId == live.paneId ? session.outputText : "",
                emptyMessage: "Watching \(live.paneId) — output pins to the tail.",
                pendingEcho: input.terminalBuffer,
                onReachTop: openHistory
            )
            Rectangle().fill(HerdrInk.rule).frame(height: 1)
            TerminalInputDock(
                terminalBuffer: $input.terminalBuffer,
                errorMessage: actionError ?? input.actionError ?? session.lastError,
                onKey: { key in Task { await handleKey(key) } },
                onTerminalChange: scheduleTerminalForward
            )
        }
        .background(HerdrInk.void)
        .pullDownToDismissKeyboard()
        .navigationTitle(live.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(HerdrInk.void, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                AgentNavIdentity(title: live.displayTitle, state: live.state, paneId: live.paneId)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Output History") {
                        openHistory()
                    }
                    if canInterrupt {
                        Button("Interrupt") {
                            Task { await interrupt() }
                        }
                    }
                    Button("Close Pane…", role: .destructive) {
                        showClosePane = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(HerdrInk.paper)
                        .accessibilityLabel("Agent actions")
                }
            }
        }
        .confirmationDialog("Close Pane?", isPresented: $showClosePane, titleVisibility: .visible) {
            Button("Close Pane", role: .destructive) {
                let paneId = live.paneId
                Task { await closePane(id: paneId) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(CloseScopeCopy.paneMessage(title: live.displayTitle, paneId: live.paneId))
        }
        .sheet(isPresented: $showHistory) {
            NavigationStack {
                TerminalHistoryView(paneId: live.paneId, title: live.displayTitle)
            }
            .preferredColorScheme(.dark)
            .tint(HerdrInk.phosphor)
        }
        .onChange(of: live.state) { _, newState in
            if newState != "done" {
                acknowledgementMessage = nil
            }
        }
        .onDisappear { input.reset() }
    }

    /// Interrupt is non-destructive (ctrl+c, layout stays). Only while the agent is busy.
    private var canInterrupt: Bool {
        let state = live.state.lowercased()
        return state == "working" || state == "running"
    }

    private var showsRibbon: Bool {
        let display = live.display
        return [
            display?.model,
            display?.repo,
            display?.branch,
            display?.cost
        ].contains { chip in
            guard let chip else { return false }
            return !chip.isEmpty
        } || !live.cwd.isEmpty
    }

    private var compactAcknowledge: some View {
        Button {
            Task { await acknowledge() }
        } label: {
            HStack(spacing: 6) {
                if isAcknowledging {
                    ProgressView()
                        .tint(HerdrInk.tide)
                        .controlSize(.mini)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: acknowledgementMessage != nil ? "checkmark.circle.fill" : "checkmark.circle")
                }
                Text(isAcknowledging ? "Acknowledging…" : (acknowledgementMessage != nil ? "Acknowledged" : "Acknowledge"))
                    .font(HerdrType.meta)
            }
            .foregroundStyle(isAcknowledging ? HerdrInk.mute : HerdrInk.void)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isAcknowledging ? HerdrInk.rule : HerdrInk.tide, in: Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAcknowledging)
        .accessibilityHint("Marks this done agent as seen")
        .accessibilityLabel(isAcknowledging ? "Acknowledging agent" : "Acknowledge")
        .accessibilityValue(isAcknowledging ? "In progress" : "")
    }

    private func openHistory() {
        dismissActiveKeyboard()
        showHistory = true
    }

    private func acknowledge() async {
        guard !isAcknowledging else { return }
        let target = live.paneId
        isAcknowledging = true
        acknowledgementMessage = nil
        announce("Acknowledging agent")
        defer { isAcknowledging = false }
        do {
            try await session.acknowledge(target: target)
            actionError = nil
            acknowledgementMessage = "Acknowledged"
            announce("Acknowledged")
        } catch {
            acknowledgementMessage = nil
            actionError = error.localizedDescription
            announce("Error, \(error.localizedDescription)")
        }
    }

    private func announce(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func interrupt() async {
        guard canInterrupt else { return }
        do {
            try await session.sendKeys(target: live.paneId, keys: ["ctrl+c"])
            actionError = nil
            announce("Interrupted")
        } catch {
            actionError = error.localizedDescription
            announce("Error, \(error.localizedDescription)")
        }
    }

    private func closePane(id: String) async {
        guard !isClosing else { return }
        isClosing = true
        defer { isClosing = false }
        do {
            try await session.closePane(id: id)
            actionError = nil
            announce("Pane closed")
            dismiss()
        } catch {
            actionError = error.localizedDescription
            announce("Error, \(error.localizedDescription)")
        }
    }

    private func handleKey(_ key: String) async {
        await input.handleKey(key) { [live] keys in
            try await session.sendKeys(target: live.paneId, keys: keys)
        }
    }

    private func scheduleTerminalForward(_ newValue: String) {
        input.scheduleTerminalForward(
            newValue,
            sendText: { [live] text in try await session.sendPaneInput(paneId: live.paneId, text: text) },
            sendKeys: { [live] keys in try await session.sendKeys(target: live.paneId, keys: keys) }
        )
    }
}

private struct AgentNavIdentity: View {
    var title: String
    var state: String
    var paneId: String

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(HerdrType.body)
                .fontWeight(.semibold)
                .foregroundStyle(HerdrInk.paper)
                .lineLimit(1)
            HStack(spacing: 6) {
                CompactStateMark(state: state)
                Text(paneId)
                    .font(HerdrType.meta)
                    .foregroundStyle(HerdrInk.mute)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Agent \(title), state \(AgentState.label(state)), pane \(paneId)")
    }
}

private struct CompactStateMark: View {
    var state: String

    var body: some View {
        let label = AgentState.label(state)
        let color = AgentState.color(state)
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(HerdrType.meta)
                .foregroundStyle(color)
                .textCase(.uppercase)
        }
        .accessibilityHidden(true)
    }
}

private struct AgentMetadataRibbon<Accessory: View>: View {
    var agent: AgentSnapshot
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                chipStack
                Spacer(minLength: 0)
                accessory()
            }
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    chipStack
                }
                Spacer(minLength: 0)
                accessory()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(HerdrInk.panel)
    }

    private var chipStack: some View {
        let display = agent.display
        return HStack(spacing: 6) {
            chips(display)
        }
    }

    @ViewBuilder
    private func chips(_ display: AgentDisplay?) -> some View {
        if let model = display?.model, !model.isEmpty {
            StatusChip(label: model)
        }
        if let repo = display?.repo, !repo.isEmpty {
            StatusChip(label: repo)
        }
        if let branch = display?.branch, !branch.isEmpty {
            StatusChip(label: branch)
        }
        if let cost = display?.cost, !cost.isEmpty {
            StatusChip(label: cost, emphasis: true)
        }
        if !agent.cwd.isEmpty {
            StatusChip(label: compactCwd)
                .accessibilityLabel("Working directory \(agent.cwd)")
        }
    }

    private var compactCwd: String {
        let leaf = URL(fileURLWithPath: agent.cwd).lastPathComponent
        return leaf.isEmpty ? agent.cwd : leaf
    }
}
