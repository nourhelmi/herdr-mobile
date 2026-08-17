import Foundation

@MainActor
@Observable
final class SessionController {
    let settings = SettingsStore()

    var snapshot: Snapshot?
    var phase: ConnectionPhase = .offline
    var herdrOK: Bool?
    var lastError: String?
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

    func sendPrompt(target: String, text: String) async throws {
        try await client.sendPrompt(target: target, text: text)
    }

    func sendKeys(target: String, keys: [String]) async throws {
        try await client.sendKeys(target: target, keys: keys)
    }

    func sendPaneInput(paneId: String, text: String) async throws {
        try await client.sendPaneInput(paneId: paneId, text: text)
    }

    func createWorkspace(label: String?) async throws {
        try await client.createWorkspace(label: label)
        await refresh()
    }

    func createTab(workspaceId: String, label: String?) async throws {
        try await client.createTab(workspaceId: workspaceId, label: label)
        await refresh()
    }

    func probeHealth() async throws -> HealthResponse {
        let health = try await client.health()
        herdrOK = health.herdr
        return health
    }
}
