import DispatchCore
import Foundation

actor RelayClient {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var socket: URLSessionWebSocketTask?

    init() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func connect(to url: URL, host: DispatchHost, bearerToken: String) async throws {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        try await send(RelayEnvelope(payload: .hello(host)))
    }

    func disconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    func send(_ envelope: RelayEnvelope) async throws {
        guard let socket else { throw RelayClientError.notConnected }
        let data = try encoder.encode(envelope)
        try await socket.send(.data(data))
    }

    func receive() async throws -> RelayEnvelope {
        guard let socket else { throw RelayClientError.notConnected }
        switch try await socket.receive() {
        case .data(let data):
            return try decoder.decode(RelayEnvelope.self, from: data)
        case .string(let text):
            return try decoder.decode(RelayEnvelope.self, from: Data(text.utf8))
        @unknown default:
            throw RelayClientError.unsupportedMessage
        }
    }
}

enum RelayClientError: LocalizedError {
    case notConnected
    case unsupportedMessage

    var errorDescription: String? {
        switch self {
        case .notConnected: "The desktop agent is not connected to a relay."
        case .unsupportedMessage: "The relay sent an unsupported WebSocket message."
        }
    }
}
