import Foundation
import Network

/// Minimal HTTP/1.1 + SSE server built directly on Network.framework.
///
/// Deliberately dependency-free: the app already ships a 2.5 GB model, and a
/// third-party web server would add build surface for what is ultimately three
/// routes. Connections are one-shot (`Connection: close`), which removes the
/// keep-alive state machine and every pipelining edge case with it.
protocol BridgeHTTPServerDelegate: AnyObject {
    func serverDidChangeState(_ state: BridgeRunState)
    func serverStatusSnapshot() async -> BridgeStatusSnapshot
    func serverRunGeneration(
        _ request: BridgeGenerationRequest,
        onDelta: @escaping (String) -> Void
    ) async throws -> BridgeGenerationResult
    func serverDidHandle(_ activity: BridgeActivity)
}

enum BridgeServerError: LocalizedError {
    case invalidPort(UInt16)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port): "Port \(port) is not usable."
        }
    }
}

final class BridgeHTTPServer {
    static let maxBodyBytes = 16 * 1_024 * 1_024
    static let maxHeaderBytes = 32 * 1_024

    weak var delegate: BridgeHTTPServerDelegate?

    private let port: UInt16
    private let queue = DispatchQueue(label: "com.matha.atlas.bridge.http", qos: .userInitiated)
    private var listener: NWListener?

    private let tokenLock = NSLock()
    private var token = ""

    private let connectionLock = NSLock()
    private var connections: [ObjectIdentifier: BridgeConnection] = [:]
    private var didReportFailure = false

    init(port: UInt16) {
        self.port = port
    }

    func updateToken(_ newToken: String) {
        tokenLock.lock()
        token = newToken
        tokenLock.unlock()
    }

    fileprivate func isAuthorized(_ candidate: String) -> Bool {
        tokenLock.lock()
        let expected = token
        tokenLock.unlock()
        guard !expected.isEmpty else { return false }
        return BridgeTokenStore.constantTimeEquals(candidate, expected)
    }

    func start() throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw BridgeServerError.invalidPort(port)
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = false
        }

        let listener = try NWListener(using: parameters, on: endpointPort)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.delegate?.serverDidChangeState(.serving(port: self.port))
            case .failed(let error):
                // Cancelling a failed listener reports `.cancelled` straight
                // after, which would otherwise overwrite the reason with a bland
                // "Off" and leave the operator with nothing to act on.
                guard !self.didReportFailure else { return }
                self.didReportFailure = true
                self.delegate?.serverDidChangeState(.failed(Self.describe(error, port: self.port)))
                self.stop()
            case .cancelled:
                if !self.didReportFailure { self.delegate?.serverDidChangeState(.stopped) }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil

        connectionLock.lock()
        let open = connections.values
        connections.removeAll()
        connectionLock.unlock()
        open.forEach { $0.close() }
    }

    /// Turns a socket error into something an operator can act on.
    private static func describe(_ error: NWError, port: UInt16) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return "Port \(port) is already in use. Pick a different port."
        }
        return error.localizedDescription
    }

    private func accept(_ connection: NWConnection) {
        // Refuse routable peers before a single byte of request is parsed.
        guard BridgeNetwork.isTrustedPeer(connection.endpoint) else {
            connection.cancel()
            delegate?.serverDidHandle(
                BridgeActivity(summary: "Refused a connection from outside the local network", accepted: false)
            )
            return
        }

        let handler = BridgeConnection(connection: connection, server: self, queue: queue)
        let key = ObjectIdentifier(handler)
        connectionLock.lock()
        connections[key] = handler
        connectionLock.unlock()

        handler.onFinish = { [weak self] in
            guard let self else { return }
            self.connectionLock.lock()
            self.connections.removeValue(forKey: key)
            self.connectionLock.unlock()
        }
        handler.start()
    }
}

// MARK: - One connection, one request

private final class BridgeConnection {
    var onFinish: (() -> Void)?

    private let connection: NWConnection
    private unowned let server: BridgeHTTPServer
    private let queue: DispatchQueue

    private var buffer = Data()
    private var head: HTTPHead?

    /// Guards `isClosed`/`didDispatch`/`onFinish`, which are touched from both the
    /// network queue and the main-actor tasks that run inference.
    private let stateLock = NSLock()
    private var isClosed = false
    private var didDispatch = false

    init(connection: NWConnection, server: BridgeHTTPServer, queue: DispatchQueue) {
        self.connection = connection
        self.server = server
        self.queue = queue
    }

    private var closed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isClosed
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
        // Guards the *read* phase only: a peer that connects and never finishes a
        // request gets dropped. Once the request is dispatched the connection must
        // stay open for as long as inference takes — a vision read or the closing
        // review can legitimately run for minutes on a phone.
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let stillReading = !self.didDispatch
            self.stateLock.unlock()
            if stillReading { self.close() }
        }
    }

    func close() {
        stateLock.lock()
        if isClosed {
            stateLock.unlock()
            return
        }
        isClosed = true
        let callback = onFinish
        onFinish = nil
        stateLock.unlock()

        connection.cancel()
        callback?()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if error != nil {
                self.close()
                return
            }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                if self.consume() { return }
            }
            if isComplete {
                self.close()
                return
            }
            self.receive()
        }
    }

    /// Returns true when the request has been fully handed off and reading stops.
    private func consume() -> Bool {
        if head == nil {
            guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > BridgeHTTPServer.maxHeaderBytes {
                    respond(status: 431, json: ["error": ["code": "header_too_large", "message": "Request headers are too large."]])
                    return true
                }
                return false
            }
            guard let parsed = HTTPHead(raw: buffer[..<separator.lowerBound]) else {
                respond(status: 400, json: ["error": ["code": "bad_request", "message": "Malformed request line."]])
                return true
            }
            if parsed.contentLength > BridgeHTTPServer.maxBodyBytes {
                respond(status: 413, json: ["error": ["code": "payload_too_large", "message": "Request body exceeds 16 MB."]])
                return true
            }
            head = parsed
            buffer.removeSubrange(..<separator.upperBound)
        }

        guard let head else { return false }
        guard buffer.count >= head.contentLength else { return false }
        let body = buffer.prefix(head.contentLength)
        buffer.removeAll(keepingCapacity: false)
        route(head: head, body: Data(body))
        return true
    }

    // MARK: Routing

    private func route(head: HTTPHead, body: Data) {
        stateLock.lock()
        didDispatch = true
        stateLock.unlock()

        if head.method == "OPTIONS" {
            respond(status: 204, body: Data(), contentType: nil)
            return
        }

        guard let presented = head.bearerToken, server.isAuthorized(presented) else {
            server.delegate?.serverDidHandle(
                BridgeActivity(summary: "Rejected \(head.method) \(head.path): bad or missing token", accepted: false)
            )
            respond(
                status: 401,
                json: ["error": ["code": "unauthorized", "message": "A valid bridge token is required."]]
            )
            return
        }

        switch (head.method, head.path) {
        case ("GET", "/v1/health"):
            handleHealth()
        case ("POST", "/v1/generate"):
            handleGenerate(body: body, streaming: false)
        case ("POST", "/v1/generate/stream"):
            handleGenerate(body: body, streaming: true)
        default:
            respond(
                status: 404,
                json: ["error": ["code": "not_found", "message": "Unknown route \(head.method) \(head.path)."]]
            )
        }
    }

    private func handleHealth() {
        Task { [weak self] in
            guard let self, let delegate = self.server.delegate else { return }
            let snapshot = await delegate.serverStatusSnapshot()
            self.respond(status: 200, json: [
                "service": "matha-atlas-inference-bridge",
                "protocol": 1,
                "model": snapshot.model,
                "engine": snapshot.engine,
                "acceptsWork": snapshot.acceptsWork,
                "vision": true,
                "structuredOutput": true,
                "servedRequests": snapshot.servedRequests
            ])
        }
    }

    private func handleGenerate(body: Data, streaming: Bool) {
        let request: BridgeGenerationRequest
        do {
            request = try BridgeRequestDecoder.decode(body)
        } catch let error as BridgeInferenceError {
            respond(status: error.httpStatus, json: ["error": ["code": error.bridgeCode, "message": error.localizedDescription]])
            return
        } catch {
            respond(status: 400, json: ["error": ["code": "invalid_request", "message": error.localizedDescription]])
            return
        }

        if streaming { beginEventStream() }

        Task { [weak self] in
            guard let self, let delegate = self.server.delegate else { return }
            do {
                let result = try await delegate.serverRunGeneration(request) { [weak self] delta in
                    guard streaming else { return }
                    self?.sendEvent(name: "delta", json: ["text": delta])
                }
                delegate.serverDidHandle(
                    BridgeActivity(
                        summary: "Answered a \(request.images.isEmpty ? "text" : "vision") request in \(String(format: "%.1f", result.timeToFirstToken))s TTFT",
                        accepted: true
                    )
                )
                let payload: [String: Any] = [
                    "text": result.text,
                    "metrics": [
                        "promptTokens": result.promptTokens,
                        "outputTokens": result.outputTokens,
                        "timeToFirstToken": result.timeToFirstToken,
                        "outputTokensPerSecond": result.outputTokensPerSecond
                    ]
                ]
                if streaming {
                    self.sendEvent(name: "done", json: payload)
                    self.close()
                } else {
                    self.respond(status: 200, json: payload)
                }
            } catch {
                let inferenceError = error as? BridgeInferenceError
                let code = inferenceError?.bridgeCode ?? "inference_failed"
                let message = inferenceError?.localizedDescription ?? error.localizedDescription
                delegate.serverDidHandle(BridgeActivity(summary: "Request failed: \(message)", accepted: false))
                if streaming {
                    self.sendEvent(name: "error", json: ["code": code, "message": message])
                    self.close()
                } else {
                    self.respond(
                        status: inferenceError?.httpStatus ?? 500,
                        json: ["error": ["code": code, "message": message]]
                    )
                }
            }
        }
    }

    // MARK: Writing

    private static let corsHeaders = [
        "Access-Control-Allow-Origin: *",
        "Access-Control-Allow-Methods: GET, POST, OPTIONS",
        "Access-Control-Allow-Headers: authorization, content-type, x-atlas-token",
        "Access-Control-Max-Age: 600"
    ]

    private func respond(status: Int, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        respond(status: status, body: body, contentType: "application/json; charset=utf-8")
    }

    private func respond(status: Int, body: Data, contentType: String?) {
        var lines = ["HTTP/1.1 \(status) \(Self.reason(for: status))"]
        lines.append(contentsOf: Self.corsHeaders)
        if let contentType { lines.append("Content-Type: \(contentType)") }
        lines.append("Content-Length: \(body.count)")
        lines.append("Cache-Control: no-store")
        lines.append("Connection: close")
        lines.append("")
        lines.append("")

        var payload = Data(lines.joined(separator: "\r\n").utf8)
        payload.append(body)
        write(payload) { [weak self] in self?.close() }
    }

    private func beginEventStream() {
        var lines = ["HTTP/1.1 200 OK"]
        lines.append(contentsOf: Self.corsHeaders)
        lines.append("Content-Type: text/event-stream; charset=utf-8")
        lines.append("Cache-Control: no-store")
        lines.append("X-Accel-Buffering: no")
        lines.append("Connection: close")
        lines.append("")
        lines.append("")
        write(Data(lines.joined(separator: "\r\n").utf8), completion: nil)
    }

    private func sendEvent(name: String, json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let encoded = String(data: data, encoding: .utf8) else { return }
        write(Data("event: \(name)\ndata: \(encoded)\n\n".utf8), completion: nil)
    }

    private func write(_ data: Data, completion: (() -> Void)?) {
        // `NWConnection.send` is already ordered per connection, so no send lock is
        // needed; only the closed check has to be synchronised.
        guard !closed else { return }
        connection.send(content: data, completion: .contentProcessed { _ in completion?() })
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 431: "Request Header Fields Too Large"
        case 503: "Service Unavailable"
        default: "Error"
        }
    }
}

// MARK: - Request head

private struct HTTPHead {
    let method: String
    let path: String
    let headers: [String: String]
    let contentLength: Int

    var bearerToken: String? {
        if let authorization = headers["authorization"] {
            let parts = authorization.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if parts.count == 2, parts[0].lowercased() == "bearer" {
                return String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return headers["x-atlas-token"]
    }

    init?(raw: Data) {
        guard let text = String(data: raw, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        method = String(requestLine[0]).uppercased()
        // Query strings are not used by any route; drop them rather than ignore them.
        path = String(String(requestLine[1]).split(separator: "?", maxSplits: 1)[0])

        var parsed: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            parsed[key] = value
        }
        headers = parsed
        contentLength = Int(parsed["content-length"] ?? "0") ?? 0
    }
}

// MARK: - Body decoding

enum BridgeRequestDecoder {
    static func decode(_ body: Data) throws -> BridgeGenerationRequest {
        guard !body.isEmpty,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw BridgeInferenceError.emptyPrompt
        }

        let prompt = (object["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prompt.isEmpty else { throw BridgeInferenceError.emptyPrompt }

        var request = BridgeGenerationRequest(prompt: String(prompt.prefix(BridgeGenerationRequest.promptLimit)))

        if let system = (object["system"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !system.isEmpty {
            request.system = String(system.prefix(8_000))
        }

        if let images = object["images"] as? [String] {
            request.images = images
                .prefix(BridgeGenerationRequest.imageCountLimit)
                .compactMap { Data(base64Encoded: stripDataURLPrefix($0), options: [.ignoreUnknownCharacters]) }
                .filter { !$0.isEmpty && $0.count <= 6 * 1_024 * 1_024 }
        }

        if let value = object["maxOutputTokens"] as? Int { request.maxOutputTokens = min(max(value, 16), 2_048) }
        if let value = object["temperature"] as? Double { request.temperature = min(max(value, 0), 1.5) }
        if let value = object["topP"] as? Double { request.topP = min(max(value, 0.1), 1) }
        if let value = object["topK"] as? Int { request.topK = min(max(value, 1), 100) }
        if let value = object["thinking"] as? Bool { request.thinkingEnabled = value }
        if let value = object["thinkingBudget"] as? Int { request.thinkingBudget = min(max(value, 0), 1_024) }
        if request.thinkingEnabled && request.thinkingBudget == 0 { request.thinkingBudget = 256 }

        if let schema = object["jsonSchema"] as? [String: Any] {
            guard JSONSerialization.isValidJSONObject(schema) else { throw BridgeInferenceError.invalidSchema }
            request.jsonSchema = schema
        }

        return request
    }

    private static func stripDataURLPrefix(_ value: String) -> String {
        guard value.hasPrefix("data:"), let comma = value.firstIndex(of: ",") else { return value }
        return String(value[value.index(after: comma)...])
    }
}
