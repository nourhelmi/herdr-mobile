import Foundation

struct Snapshot: Codable, Equatable, Sendable {
    var generatedAt: String
    var workspaces: [WorkspaceSnapshot]
    var agents: [AgentSnapshot]
}

struct WorkspaceSnapshot: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var label: String
    var number: Int
    var focused: Bool
    var agentStatus: String
    var tabs: [TabSnapshot]
}

struct TabSnapshot: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var label: String
    var number: Int
    var focused: Bool
    var agentStatus: String
    var panes: [PaneSnapshot]
}

struct PaneSnapshot: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var label: String?
    var title: String
    var cwd: String
    var isAgent: Bool
    var agent: AgentSnapshot?
}

struct AgentSnapshot: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var displayName: String?
    var paneId: String
    var workspaceId: String
    var tabId: String
    var state: String
    var cwd: String
    var paneLabel: String?

    var id: String { paneId }

    var displayTitle: String {
        if let displayName, !displayName.isEmpty { return displayName }
        if let paneLabel, !paneLabel.isEmpty { return "\(name) · \(paneLabel)" }
        return name
    }
}

struct HealthResponse: Codable, Equatable, Sendable {
    var ok: Bool
    var version: String
    var herdr: Bool
}

struct PaneOutputResponse: Codable, Equatable, Sendable {
    var paneId: String
    var format: String
    var text: String
}

struct OKResponse: Codable, Equatable, Sendable {
    var ok: Bool
    var error: String?
}

enum ServerEvent: Equatable, Sendable {
    case state(Snapshot)
    case output(paneId: String, text: String, format: String)
    case error(String)
}

enum ConnectionPhase: Equatable, Sendable {
    case offline
    case connecting
    case live
    case reconnecting
}

struct HerdrClientError: LocalizedError, Equatable {
    var statusCode: Int?
    var message: String

    var errorDescription: String? { message }

    static func decode(_ data: Data, status: Int) -> HerdrClientError {
        if let body = try? JSONDecoder().decode(OKResponse.self, from: data),
           let error = body.error, !error.isEmpty {
            return HerdrClientError(statusCode: status, message: error)
        }
        return HerdrClientError(statusCode: status, message: "Request failed (\(status))")
    }
}

enum ServerEventDecoder {
    static func decode(_ data: Data) throws -> ServerEvent {
        let envelope = try JSONDecoder().decode(EventEnvelope.self, from: data)
        switch envelope.type {
        case "state":
            guard let state = envelope.state else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "state event missing state"))
            }
            return .state(state)
        case "output":
            guard let paneId = envelope.paneId, let text = envelope.text else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "output event missing fields"))
            }
            return .output(paneId: paneId, text: text, format: envelope.format ?? "text")
        case "error":
            return .error(envelope.message ?? "Unknown sidecar error")
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unknown event type \(envelope.type)"))
        }
    }

    private struct EventEnvelope: Decodable {
        var type: String
        var state: Snapshot?
        var paneId: String?
        var text: String?
        var format: String?
        var message: String?
    }
}
