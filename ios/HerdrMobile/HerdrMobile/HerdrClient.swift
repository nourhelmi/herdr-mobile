import Foundation

/// HTTP + one `URLSessionWebSocketTask`. Actions stay on HTTP; watch is WS-only.
@MainActor
final class HerdrClient {
    var onState: ((Snapshot) -> Void)?
    var onOutput: ((String, String) -> Void)?
    var onSocketError: ((String) -> Void)?
    var onPhase: ((ConnectionPhase) -> Void)?

    private let httpSession: URLSession
    private let socketSession: URLSession
    private var socketTask: URLSessionWebSocketTask?
    private var runTask: Task<Void, Never>?
    private var baseURL: URL?
    private var watchedPaneId: String?
    private var watchedLines = 200
    private var watchedFormat = "ansi"
    private var backoff: TimeInterval = 1

    init() {
        let http = URLSessionConfiguration.ephemeral
        http.timeoutIntervalForRequest = 15
        http.timeoutIntervalForResource = 30
        http.waitsForConnectivity = true
        httpSession = URLSession(configuration: http)

        let socket = URLSessionConfiguration.default
        socket.waitsForConnectivity = true
        socket.timeoutIntervalForRequest = 60
        socketSession = URLSession(configuration: socket)
    }

    func setBaseURL(_ url: URL?) {
        let changed = url?.absoluteString != baseURL?.absoluteString
        baseURL = url
        if changed {
            disconnect()
            if url != nil { connect() }
        }
    }

    func connect() {
        guard baseURL != nil else {
            onPhase?(.offline)
            return
        }
        runTask?.cancel()
        backoff = 1
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func disconnect() {
        runTask?.cancel()
        runTask = nil
        socketTask?.cancel(with: .goingAway, reason: nil)
        socketTask = nil
        onPhase?(.offline)
    }

    func watch(paneId: String, lines: Int = 200, format: String = "ansi") {
        watchedPaneId = paneId
        watchedLines = lines
        watchedFormat = format
        Task { await sendWatchIfNeeded() }
    }

    func unwatch() {
        watchedPaneId = nil
        Task { await sendUnwatch() }
    }

    func health() async throws -> HealthResponse {
        try await get(path: "/health")
    }

    func fetchState() async throws -> Snapshot {
        try await get(path: "/state")
    }

    func paneOutput(paneId: String, lines: Int = 200) async throws -> PaneOutputResponse {
        try await get(path: "/pane/\(Self.encodePath(paneId))/output", query: [
            URLQueryItem(name: "lines", value: String(lines)),
            URLQueryItem(name: "format", value: "text"),
        ])
    }

    func sendPrompt(target: String, text: String) async throws {
        try await post(path: "/agent/\(Self.encodePath(target))/prompt", body: ["text": text])
    }

    func sendKeys(target: String, keys: [String]) async throws {
        try await post(path: "/agent/\(Self.encodePath(target))/keys", body: ["keys": keys])
    }

    func sendPaneInput(paneId: String, text: String) async throws {
        try await post(path: "/pane/\(Self.encodePath(paneId))/input", body: ["text": text])
    }

    func createWorkspace(label: String?) async throws {
        var body: [String: Any] = [:]
        if let label, !label.isEmpty { body["label"] = label }
        try await post(path: "/workspace", body: body)
    }

    func createTab(workspaceId: String, label: String?) async throws {
        var body: [String: Any] = [:]
        if let label, !label.isEmpty { body["label"] = label }
        try await post(path: "/workspace/\(Self.encodePath(workspaceId))/tab", body: body)
    }

    func acknowledge(target: String) async throws {
        try await post(path: "/agent/\(Self.encodePath(target))/acknowledge")
    }

    func closePane(id: String) async throws {
        try await delete(path: "/pane/\(Self.encodePath(id))")
    }

    func closeTab(id: String) async throws {
        try await delete(path: "/tab/\(Self.encodePath(id))")
    }

    func closeWorkspace(id: String) async throws {
        try await delete(path: "/workspace/\(Self.encodePath(id))")
    }

    /// Protocol: `:` in pane ids must be `%3A`.
    static func encodePath(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func webSocketURL(from base: URL) -> URL? {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        switch components?.scheme?.lowercased() {
        case "https": components?.scheme = "wss"
        case "http": components?.scheme = "ws"
        default: return nil
        }
        let path = (components?.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.path = path.isEmpty ? "/ws" : "/\(path)/ws"
        components?.query = nil
        return components?.url
    }

    private func runLoop() async {
        while !Task.isCancelled {
            guard let baseURL, let wsURL = Self.webSocketURL(from: baseURL) else {
                onPhase?(.offline)
                return
            }
            onPhase?(backoff == 1 ? .connecting : .reconnecting)
            do {
                try await receiveUntilClose(url: wsURL)
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled {
                    onSocketError?(error.localizedDescription)
                }
            }
            socketTask?.cancel(with: .goingAway, reason: nil)
            socketTask = nil
            guard !Task.isCancelled else { return }
            onPhase?(.reconnecting)
            let delay = backoff
            backoff = min(backoff * 2, 30)
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func receiveUntilClose(url: URL) async throws {
        let task = socketSession.webSocketTask(with: url)
        socketTask = task
        task.resume()
        // First successful receive (the connect `state` frame) proves the socket is live.
        let first = try await task.receive()
        backoff = 1
        onPhase?(.live)
        try handle(first)
        await sendWatchIfNeeded()

        while !Task.isCancelled {
            let message = try await task.receive()
            try handle(message)
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) throws {
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let value):
            data = value
        @unknown default:
            return
        }
        switch try ServerEventDecoder.decode(data) {
        case .state(let snapshot):
            onState?(snapshot)
        case .output(let paneId, let text, _):
            onOutput?(paneId, text)
        case .error(let message):
            onSocketError?(message)
        }
    }

    private func sendWatchIfNeeded() async {
        guard let paneId = watchedPaneId else { return }
        await send(json: ["type": "watch", "paneId": paneId, "lines": watchedLines, "format": watchedFormat])
    }

    private func sendUnwatch() async {
        await send(json: ["type": "unwatch"])
    }

    private func send(json: [String: Any]) async {
        guard let task = socketTask,
              let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8)
        else { return }
        try? await task.send(.string(text))
    }

    private func get<T: Decodable>(path: String, query: [URLQueryItem] = []) async throws -> T {
        var request = try makeRequest(path: path, query: query)
        request.httpMethod = "GET"
        return try await send(request)
    }

    private func post(path: String, body: [String: Any]) async throws {
        var request = try makeRequest(path: path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let _: OKResponse = try await send(request)
    }

    /// Bodyless POST: no Content-Type and no `{}`.
    private func post(path: String) async throws {
        var request = try makeRequest(path: path)
        request.httpMethod = "POST"
        let _: OKResponse = try await send(request)
    }

    /// Bodyless DELETE: no Content-Type and no `{}`.
    private func delete(path: String) async throws {
        var request = try makeRequest(path: path)
        request.httpMethod = "DELETE"
        let _: OKResponse = try await send(request)
    }

    private func makeRequest(path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard let baseURL else {
            throw HerdrClientError(message: "Set a sidecar base URL in Settings")
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw HerdrClientError(message: "Invalid sidecar URL")
        }
        let prefix = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        // `path` already contains encoded path components (for example `%3A` in pane IDs).
        // Assign through percentEncodedPath so URLComponents does not escape the `%` again.
        components.percentEncodedPath = prefix + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw HerdrClientError(message: "Invalid sidecar URL")
        }
        return URLRequest(url: url)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await httpSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw HerdrClientError.decode(data, status: status)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
