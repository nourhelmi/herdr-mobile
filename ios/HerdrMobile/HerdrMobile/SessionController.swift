import Foundation

@MainActor
@Observable
final class SessionController {
    let settings = SettingsStore()

    var snapshot: Snapshot?
    var phase: ConnectionPhase = .offline
    var herdrOK: Bool?
    var lastError: String?
    /// Mild close-lag copy. Not an error; views must not route this through ErrorBanner.
    var notice: String?
    /// True after a 502-was-closed close: GET /state can only be the pre-close tree.
    var structureStale = false
    var outputText = ""
    var outputPaneId: String?
    var isRefreshing = false

    private let client = HerdrClient()
    private var started = false

    var rankedAgents: [AgentSnapshot] {
        (snapshot?.agents ?? []).sorted { lhs, rhs in
            let left = AgentState.rank(lhs.state)
            let right = AgentState.rank(rhs.state)
            if left != right { return left < right }
            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        }
    }

    var orderedWorkspaces: [WorkspaceSnapshot] {
        (snapshot?.workspaces ?? []).sorted { $0.number < $1.number }
    }

    func start() {
        guard !started else { return }
        started = true
        client.onState = { [weak self] snapshot in
            self?.snapshot = snapshot
            self?.lastError = nil
            self?.structureStale = false
        }
        client.onOutput = { [weak self] paneId, text in
            guard let self, self.outputPaneId == paneId else { return }
            self.outputText = text
        }
        client.onSocketError = { [weak self] message in
            self?.lastError = message
        }
        client.onPhase = { [weak self] phase in
            self?.phase = phase
        }
        applyBaseURL()
    }

    func applyBaseURL() {
        client.setBaseURL(settings.baseURL)
        if settings.baseURL == nil {
            lastError = "Sidecar URL is invalid"
            snapshot = nil
        }
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let health = client.health()
            async let state = client.fetchState()
            let (healthValue, stateValue) = try await (health, state)
            herdrOK = healthValue.herdr
            snapshot = stateValue
            structureStale = false
            notice = nil
            lastError = healthValue.herdr ? nil : "Sidecar is up; last Herdr poll failed"
        } catch {
            lastError = error.localizedDescription
        }
    }

    func watch(paneId: String) {
        if outputPaneId != paneId {
            outputText = ""
            outputPaneId = paneId
        }
        client.watch(paneId: paneId)
    }

    func unwatch() {
        client.unwatch()
        outputPaneId = nil
        outputText = ""
    }

    func sendKeys(target: String, keys: [String]) async throws {
        try await client.sendKeys(target: target, keys: keys)
    }

    func sendPaneKeys(paneId: String, keys: [String]) async throws {
        try await client.sendPaneKeys(paneId: paneId, keys: keys)
    }

    func sendPaneInput(paneId: String, text: String) async throws {
        try await client.sendPaneInput(paneId: paneId, text: text)
    }

    func createWorkspace(label: String?) async throws {
        try await client.createWorkspace(label: label)
        try await refreshSnapshot(after: "Workspace was created")
    }

    func createTab(workspaceId: String, label: String?) async throws {
        try await client.createTab(workspaceId: workspaceId, label: label)
        try await refreshSnapshot(after: "Tab was created")
    }

    func acknowledge(target: String) async throws {
        try await client.acknowledge(target: target)
        try await refreshSnapshot(after: "Agent was acknowledged")
    }

    func closePane(id: String) async throws {
        try await closeResource(phrase: "Pane was closed") {
            try await client.closePane(id: id)
        }
    }

    func closeTab(id: String) async throws {
        try await closeResource(phrase: "Tab was closed") {
            try await client.closeTab(id: id)
        }
    }

    func closeWorkspace(id: String) async throws {
        try await closeResource(phrase: "Workspace was closed") {
            try await client.closeWorkspace(id: id)
        }
    }

    func clearNotice() {
        notice = nil
    }

    /// Close argv is done (2xx or sidecar 502-was-closed). Always GET `/state`.
    /// 502-was-closed means the sidecar poll failed before assigning current —
    /// the fetched tree is stale. Never claim a reload on that path.
    private func closeResource(phrase: String, op: () async throws -> Void) async throws {
        var sidecarLagged = false
        do {
            try await op()
        } catch let error as HerdrClientError where error.isClosedPartialSuccess {
            sidecarLagged = true
        }
        let clientRefreshFailed = await reloadSnapshotAfterClose()
        if sidecarLagged {
            structureStale = true
            notice = "\(phrase), but state refresh failed. Pull to refresh before retrying."
            return
        }
        if clientRefreshFailed {
            notice = "\(phrase), but the tree could not be reloaded. Pull to refresh."
            return
        }
        structureStale = false
        notice = nil
    }

    private func reloadSnapshotAfterClose() async -> Bool {
        do {
            snapshot = try await client.fetchState()
            lastError = nil
            return false
        } catch {
            return true
        }
    }

    /// Confirmed mutation already happened; a failed `/state` fetch is partial success.
    private func refreshSnapshot(after completedAction: String) async throws {
        do {
            snapshot = try await client.fetchState()
            lastError = nil
        } catch {
            let message = "\(completedAction), but fresh state could not be loaded; pull to refresh before retrying"
            lastError = message
            throw HerdrClientError(message: message)
        }
    }

    func probeHealth() async throws -> HealthResponse {
        let health = try await client.health()
        herdrOK = health.herdr
        return health
    }
}
