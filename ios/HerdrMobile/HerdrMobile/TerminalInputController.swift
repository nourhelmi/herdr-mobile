import Foundation

/// Serialized terminal composer state shared by agent and bare-pane detail screens.
/// Transport (agent keys vs. pane keys; both share pane-scoped text input) is supplied
/// per call so the same revision/erase logic works for either endpoint.
@MainActor
@Observable
final class TerminalInputController {
    var terminalBuffer = ""
    var actionError: String?

    private var lastForwarded = ""
    private var inputRevision = 0
    private var inputTask: Task<Void, Never>?
    private var terminalWriteTask: Task<Void, Never>?

    /// Call on disappear: cancels in-flight writes and clears the pending buffer.
    func reset() {
        inputRevision += 1
        inputTask?.cancel()
        terminalWriteTask?.cancel()
        terminalBuffer = ""
        lastForwarded = ""
    }

    func handleKey(_ key: String, sendKeys: @escaping ([String]) async throws -> Void) async {
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
            try await sendKeys([key])
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Immediate leading edge: enqueue now. The write queue serializes sends;
    /// stale revisions drop after the in-flight write so typing never waits for a pause.
    func scheduleTerminalForward(
        _ newValue: String,
        sendText: @escaping (String) async throws -> Void,
        sendKeys: @escaping ([String]) async throws -> Void
    ) {
        inputRevision += 1
        let revision = inputRevision
        inputTask?.cancel()
        inputTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, revision == self.inputRevision else { return }
            await self.queueTerminalInput(newValue, revision: revision, sendText: sendText, sendKeys: sendKeys)
        }
    }

    /// Serialize terminal writes so an older request cannot race a newer edit.
    private func queueTerminalInput(
        _ newValue: String,
        revision: Int,
        sendText: @escaping (String) async throws -> Void,
        sendKeys: @escaping ([String]) async throws -> Void
    ) async {
        let previous = terminalWriteTask
        let write = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, revision == self.inputRevision else { return }
            await self.forwardDelta(newValue, sendText: sendText, sendKeys: sendKeys)
        }
        terminalWriteTask = write
        await write.value
    }

    private func forwardDelta(
        _ newValue: String,
        sendText: @escaping (String) async throws -> Void,
        sendKeys: @escaping ([String]) async throws -> Void
    ) async {
        let old = lastForwarded
        guard newValue != old else { return }
        do {
            if newValue.hasPrefix(old) {
                let delta = String(newValue.dropFirst(old.count))
                if !delta.isEmpty {
                    try await sendText(delta)
                }
            } else if old.hasPrefix(newValue) {
                try await eraseTerminalText(from: old, to: newValue, sendKeys: sendKeys)
            } else {
                try await eraseTerminalText(from: old, to: "", sendKeys: sendKeys)
                if !newValue.isEmpty {
                    try await sendText(newValue)
                }
            }
            lastForwarded = newValue
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// The sidecar accepts at most 32 keys per request; retain partial progress on a later failure.
    private func eraseTerminalText(
        from old: String,
        to new: String,
        sendKeys: @escaping ([String]) async throws -> Void
    ) async throws {
        var current = old
        while current.count > new.count {
            let batchSize = min(current.count - new.count, 32)
            try await sendKeys(Array(repeating: "backspace", count: batchSize))
            current = String(current.dropLast(batchSize))
            lastForwarded = current
        }
    }
}
