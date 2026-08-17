import SwiftUI

private enum AgentViewMode: String, CaseIterable {
    case prompt
    case terminal
}

struct AgentDetailView: View {
    @Environment(SessionController.self) private var session
    let agent: AgentSnapshot

    @State private var mode = AgentViewMode.prompt
    @State private var prompt = ""
    @State private var terminalBuffer = ""
    @State private var lastForwarded = ""
    @State private var inputRevision = 0
    @State private var inputTask: Task<Void, Never>?
    @State private var terminalWriteTask: Task<Void, Never>?
    @State private var isSending = false
    @State private var actionError: String?

    private var live: AgentSnapshot {
        session.snapshot?.agents.first { $0.paneId == agent.paneId } ?? agent
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(HerdrInk.rule).frame(height: 1)
            TerminalOutputView(
                text: session.outputPaneId == live.paneId ? session.outputText : "",
                emptyMessage: mode == .prompt
                    ? "Watching \(live.paneId) — chrome stays off the page."
                    : "Watching \(live.paneId) — full TUI, colors on.",
                colorize: mode == .terminal,
                trimChrome: mode == .prompt
            )
            Rectangle().fill(HerdrInk.rule).frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                ErrorBanner(message: actionError ?? session.lastError)
                QuickKeysBar(enabled: !isSending, extended: mode == .terminal) { key in
                    Task { await handleKey(key) }
                }
                if mode == .prompt {
                    PromptComposer(text: $prompt, isSending: isSending, onSend: submitPrompt)
                } else {
                    PromptComposer(
                        text: $terminalBuffer,
                        isSending: isSending,
                        placeholder: "Type into the pane",
                        sendLabel: "RET",
                        onSend: { Task { await handleKey("enter") } }
                    )
                    .onChange(of: terminalBuffer) { _, newValue in
                        inputRevision += 1
                        let revision = inputRevision
                        inputTask?.cancel()
                        inputTask = Task { @MainActor in
                            do {
                                try await Task.sleep(for: .milliseconds(120))
                            } catch {
                                return
                            }
                            guard !Task.isCancelled, revision == inputRevision else { return }
                            await queueTerminalInput(newValue, revision: revision)
                        }
                    }
                }
            }
            .padding(12)
            .background(HerdrInk.panel)
        }
        .background(HerdrInk.void)
        .navigationTitle(live.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(HerdrInk.void, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear { session.watch(paneId: live.paneId) }
        .onDisappear {
            inputTask?.cancel()
            terminalWriteTask?.cancel()
            session.unwatch()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StateBadge(state: live.state)
                Spacer()
                modeToggle
                Text(live.paneId)
                    .font(HerdrType.meta)
                    .foregroundStyle(HerdrInk.mute)
                    .accessibilityLabel("Pane \(live.paneId)")
            }
            Text(live.displayTitle)
                .font(HerdrType.display)
                .foregroundStyle(HerdrInk.paper)
            chipRow
            if !live.cwd.isEmpty {
                Text(live.cwd)
                    .font(HerdrType.meta)
                    .foregroundStyle(HerdrInk.mute)
            }
        }
        .padding(12)
        .background(HerdrInk.panel)
    }

    private var chipRow: some View {
        let display = live.display
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                chips(display)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chips(display)
                }
            }
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
    }

    private var modeToggle: some View {
        HStack(spacing: 0) {
            modeButton(.prompt, title: "PROMPT")
            modeButton(.terminal, title: "TERM")
        }
        .overlay(Rectangle().stroke(HerdrInk.rule, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View mode")
    }

    private func modeButton(_ value: AgentViewMode, title: String) -> some View {
        Button {
            mode = value
        } label: {
            Text(title)
                .font(HerdrType.meta)
                .foregroundStyle(mode == value ? HerdrInk.void : HerdrInk.mute)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(mode == value ? HerdrInk.phosphor : HerdrInk.void)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value == .prompt ? "Prompt mode" : "Terminal mode")
        .accessibilityAddTraits(mode == value ? .isSelected : [])
    }

    private func submitPrompt() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        Task { await sendPrompt(text) }
    }

    private func sendPrompt(_ text: String) async {
        guard text.count <= 16_000 else {
            actionError = "Prompt exceeds 16000 characters"
            return
        }
        isSending = true
        defer { isSending = false }
        do {
            try await session.sendPrompt(target: live.paneId, text: text)
            prompt = ""
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func handleKey(_ key: String) async {
        if mode == .terminal, key == "enter" {
            await inputTask?.value
            inputRevision += 1
            terminalBuffer = ""
            lastForwarded = ""
        } else if mode == .terminal, key == "esc" {
            inputTask?.cancel()
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
