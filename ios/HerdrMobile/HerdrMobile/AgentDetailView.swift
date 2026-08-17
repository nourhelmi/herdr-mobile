import SwiftUI
import UIKit

struct AgentDetailView: View {
    @Environment(SessionController.self) private var session
    @Environment(\.dismiss) private var dismiss
    let agent: AgentSnapshot

    @State private var terminalBuffer = ""
    @State private var lastForwarded = ""
    @State private var inputRevision = 0
    @State private var inputTask: Task<Void, Never>?
    @State private var terminalWriteTask: Task<Void, Never>?
    @State private var actionError: String?
    @State private var isAcknowledging = false
    @State private var acknowledgementMessage: String?
    @State private var showClosePane = false
    @State private var isClosing = false

    private var live: AgentSnapshot {
        session.snapshot?.agents.first { $0.paneId == agent.paneId } ?? agent
    }

    var body: some View {
        VStack(spacing: 0) {
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
                emptyMessage: "Watching \(live.paneId) — output pins to the tail."
            )
            Rectangle().fill(HerdrInk.rule).frame(height: 1)
            AgentInputDock(
                terminalBuffer: $terminalBuffer,
                errorMessage: actionError ?? session.lastError,
                onKey: { key in Task { await handleKey(key) } },
                onTerminalChange: scheduleTerminalForward
            )
        }
        .background(HerdrInk.void)
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
        .onAppear { session.watch(paneId: live.paneId) }
        .onChange(of: live.state) { _, newState in
            if newState != "done" {
                acknowledgementMessage = nil
            }
        }
        .onDisappear {
            inputRevision += 1
            inputTask?.cancel()
            terminalWriteTask?.cancel()
            session.unwatch()
        }
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
        if key == "enter" {
            await inputTask?.value
            inputRevision += 1
            terminalBuffer = ""
            lastForwarded = ""
        } else if key == "esc" {
            inputTask?.cancel()
            // Finish an in-flight pane write before clearing its acknowledged prefix;
            // otherwise the clear callback could issue stale backspaces after ESC.
            await terminalWriteTask?.value
            inputRevision += 1
            terminalBuffer = ""
            lastForwarded = ""
        }
        do {
            try await session.sendKeys(target: live.paneId, keys: [key])
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Immediate leading edge: enqueue now. The write queue serializes POSTs;
    /// stale revisions drop after the in-flight write so typing never waits for a pause.
    private func scheduleTerminalForward(_ newValue: String) {
        inputRevision += 1
        let revision = inputRevision
        inputTask?.cancel()
        inputTask = Task { @MainActor in
            guard !Task.isCancelled, revision == inputRevision else { return }
            await queueTerminalInput(newValue, revision: revision)
        }
    }

    /// Serialize terminal writes so an older request cannot race a newer edit.
    private func queueTerminalInput(_ newValue: String, revision: Int) async {
        let previous = terminalWriteTask
        let write = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled, revision == inputRevision else { return }
            await forwardDelta(newValue)
        }
        terminalWriteTask = write
        await write.value
    }

    private func forwardDelta(_ newValue: String) async {
        let old = lastForwarded
        guard newValue != old else { return }
        do {
            if newValue.hasPrefix(old) {
                let delta = String(newValue.dropFirst(old.count))
                if !delta.isEmpty {
                    try await session.sendPaneInput(paneId: live.paneId, text: delta)
                }
            } else if old.hasPrefix(newValue) {
                try await eraseTerminalText(from: old, to: newValue)
            } else {
                try await eraseTerminalText(from: old, to: "")
                if !newValue.isEmpty {
                    try await session.sendPaneInput(paneId: live.paneId, text: newValue)
                }
            }
            lastForwarded = newValue
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// The sidecar accepts at most 32 keys per request; retain partial progress on a later failure.
    private func eraseTerminalText(from old: String, to new: String) async throws {
        var current = old
        while current.count > new.count {
            let batchSize = min(current.count - new.count, 32)
            try await session.sendKeys(
                target: live.paneId,
                keys: Array(repeating: "backspace", count: batchSize)
            )
            current = String(current.dropLast(batchSize))
            lastForwarded = current
        }
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

private struct AgentInputDock: View {
    @Binding var terminalBuffer: String
    var errorMessage: String?
    var onKey: (String) -> Void
    var onTerminalChange: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ErrorBanner(message: errorMessage)
            QuickKeysBar(enabled: true, includeEnter: true, extended: true) { key in
                onKey(key)
            }
            PromptComposer(
                text: $terminalBuffer,
                onSend: { onKey("enter") }
            )
            .onChange(of: terminalBuffer) { _, newValue in
                onTerminalChange(newValue)
            }
        }
        .padding(12)
        .background(HerdrInk.panel)
    }
}
