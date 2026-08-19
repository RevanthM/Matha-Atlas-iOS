import Foundation
import Network
import Security
import SwiftUI
import UIKit

/// Local inference bridge.
///
/// Lets a trusted app on the same device or LAN — such as the InspectAR field
/// survey client driving Meta Ray-Ban Display glasses — run prompts against the
/// Gemma model that is *already resident in this process*. It never loads a
/// second copy of the weights: every request is served by `ChatStore`'s engine.
///
/// Security posture, deliberately conservative:
///  - Off by default; the operator turns it on explicitly.
///  - Bearer token required on every route, generated locally, kept in Keychain,
///    compared in constant time.
///  - Peers outside loopback/private address space are refused before any
///    request body is read.
///  - One generation at a time; extra callers get `409 busy` instead of queueing
///    work that would starve the on-screen chat.
///  - Foreground only. iOS suspends the listener with the app, which is the
///    correct behaviour for a tool the operator is actively using.

// MARK: - Request / response models

struct BridgeGenerationRequest {
    var prompt: String
    var system: String?
    var images: [Data] = []
    var maxOutputTokens: Int = 512
    var temperature: Double = 0.2
    var topP: Double = 0.95
    var topK: Int = 40
    var thinkingEnabled: Bool = false
    var thinkingBudget: Int = 0
    /// When present, LiteRT-LM constrains decoding to this JSON schema, so the
    /// caller gets parseable structure instead of prose it has to guess at.
    var jsonSchema: [String: Any]?

    static let promptLimit = 24_000
    static let imageCountLimit = 4
}

struct BridgeGenerationResult {
    var text: String
    var promptTokens: Int
    var outputTokens: Int
    var timeToFirstToken: Double
    var outputTokensPerSecond: Double
}

enum BridgeInferenceError: LocalizedError {
    case modelNotLoaded
    case busy
    case invalidSchema
    case emptyPrompt

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "The on-device model is not loaded yet."
        case .busy: "The on-device model is handling another request."
        case .invalidSchema: "The supplied JSON schema is not valid."
        case .emptyPrompt: "The request contained no prompt text."
        }
    }

    var bridgeCode: String {
        switch self {
        case .modelNotLoaded: "model_not_loaded"
        case .busy: "busy"
        case .invalidSchema: "invalid_schema"
        case .emptyPrompt: "invalid_request"
        }
    }

    var httpStatus: Int {
        switch self {
        case .modelNotLoaded: 503
        case .busy: 409
        case .invalidSchema, .emptyPrompt: 400
        }
    }
}

/// What the HTTP layer needs from the model layer. Keeps `BridgeHTTPServer`
/// independent of `ChatStore`, which makes both testable in isolation.
@MainActor
protocol BridgeInferenceProviding: AnyObject {
    var bridgeModelName: String { get }
    var bridgeEngineState: String { get }
    var bridgeAcceptsWork: Bool { get }
    func runBridgeGeneration(
        _ request: BridgeGenerationRequest,
        onDelta: @escaping (String) -> Void
    ) async throws -> BridgeGenerationResult
}

// MARK: - Bridge controller

@MainActor
final class InferenceBridge: ObservableObject {
    static let shared = InferenceBridge()

    @Published private(set) var runState: BridgeRunState = .stopped
    @Published private(set) var lastActivity: BridgeActivity?
    @Published private(set) var servedRequests = 0
    @Published private(set) var rejectedRequests = 0

    /// Persisted operator preferences.
    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            isEnabled ? start() : stop()
        }
    }

    @Published var port: Int {
        didSet {
            let clamped = min(max(port, 1_024), 65_535)
            if clamped != port { port = clamped; return }
            guard oldValue != port else { return }
            UserDefaults.standard.set(port, forKey: Keys.port)
            if isEnabled { restart() }
        }
    }

    @Published var keepScreenAwake: Bool {
        didSet {
            guard oldValue != keepScreenAwake else { return }
            UserDefaults.standard.set(keepScreenAwake, forKey: Keys.keepAwake)
            applyIdleTimer()
        }
    }

    private(set) var token: String
    private var server: BridgeHTTPServer?
    private weak var provider: BridgeInferenceProviding?
    private var lifecycleObserver: NSObjectProtocol?

    private enum Keys {
        static let enabled = "bridge.enabled"
        static let port = "bridge.port"
        static let keepAwake = "bridge.keepScreenAwake"
    }

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Keys.enabled)
        let storedPort = defaults.integer(forKey: Keys.port)
        port = storedPort == 0 ? 8765 : min(max(storedPort, 1_024), 65_535)
        keepScreenAwake = defaults.object(forKey: Keys.keepAwake) as? Bool ?? true
        token = BridgeTokenStore.loadOrCreate()
        observeLifecycle()
    }

    /// iOS invalidates a listening socket while the app is suspended. A field tool
    /// has to come back on its own when the surveyor reopens it — nobody is going
    /// to notice a dead port halfway up a pole and flip the toggle twice.
    private func observeLifecycle() {
        lifecycleObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in InferenceBridge.shared.resumeIfNeeded() }
        }
    }

    private func resumeIfNeeded() {
        guard isEnabled else { return }
        // Ownership is tracked by `server`, not by `runState`: the run state is
        // published asynchronously from the network queue, so testing it here
        // races the listener and can build a second one that collides with the
        // first on the same port.
        guard server == nil else {
            applyIdleTimer()
            return
        }
        start()
    }

    /// Called once at launch. Creating the singleton registers the lifecycle
    /// observer and restores a previously enabled bridge, so the state does not
    /// depend on the user having reached the chat screen this session.
    func activate() {
        resumeIfNeeded()
    }

    /// Called once the chat engine exists so the bridge has something to talk to.
    func attach(provider: BridgeInferenceProviding) {
        self.provider = provider
        if isEnabled, server == nil { start() }
    }

    func detach() {
        provider = nil
    }

    func regenerateToken() {
        objectWillChange.send()
        token = BridgeTokenStore.regenerate()
        server?.updateToken(token)
    }

    /// `http://<lan-ip>:<port>` — what the operator types into the glasses client.
    var advertisedBaseURL: String {
        "http://\(BridgeNetwork.primaryLANAddress() ?? "127.0.0.1"):\(port)"
    }

    var pairingPayload: String {
        // A single string the client can paste instead of typing two fields.
        "atlas://\(BridgeNetwork.primaryLANAddress() ?? "127.0.0.1"):\(port)?token=\(token)"
    }

    // MARK: Lifecycle

    private func start() {
        stop()
        let server = BridgeHTTPServer(port: UInt16(port))
        server.delegate = self
        server.updateToken(token)
        self.server = server
        runState = .starting
        applyIdleTimer()
        do {
            try server.start()
        } catch {
            runState = .failed(error.localizedDescription)
            self.server = nil
            applyIdleTimer()
        }
    }

    private func stop() {
        server?.stop()
        server = nil
        if case .failed = runState {} else { runState = .stopped }
        applyIdleTimer()
    }

    private func restart() {
        stop()
        start()
    }

    private func applyIdleTimer() {
        let shouldStayAwake = keepScreenAwake && isEnabled && runState.isServing
        UIApplication.shared.isIdleTimerDisabled = shouldStayAwake
    }

    fileprivate func note(_ activity: BridgeActivity) {
        lastActivity = activity
        if activity.accepted { servedRequests += 1 } else { rejectedRequests += 1 }
    }
}

// MARK: - Server delegate

extension InferenceBridge: BridgeHTTPServerDelegate {
    nonisolated func serverDidChangeState(_ state: BridgeRunState) {
        Task { @MainActor in
            self.runState = state
            // Release a dead listener so the next foreground can rebuild it.
            if case .failed = state {
                self.server?.stop()
                self.server = nil
            }
            self.applyIdleTimer()
        }
    }

    nonisolated func serverStatusSnapshot() async -> BridgeStatusSnapshot {
        await MainActor.run {
            BridgeStatusSnapshot(
                model: provider?.bridgeModelName ?? "unknown",
                engine: provider?.bridgeEngineState ?? "unloaded",
                acceptsWork: provider?.bridgeAcceptsWork ?? false,
                servedRequests: servedRequests
            )
        }
    }

    nonisolated func serverRunGeneration(
        _ request: BridgeGenerationRequest,
        onDelta: @escaping (String) -> Void
    ) async throws -> BridgeGenerationResult {
        let provider = await MainActor.run { self.provider }
        guard let provider else { throw BridgeInferenceError.modelNotLoaded }
        return try await provider.runBridgeGeneration(request, onDelta: onDelta)
    }

    nonisolated func serverDidHandle(_ activity: BridgeActivity) {
        Task { @MainActor in self.note(activity) }
    }
}

// MARK: - Supporting types

enum BridgeRunState: Equatable {
    case stopped
    case starting
    case serving(port: UInt16)
    case failed(String)

    var isServing: Bool {
        if case .serving = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .stopped: "Off"
        case .starting: "Starting…"
        case .serving(let port): "Listening on port \(port)"
        case .failed(let message): "Failed: \(message)"
        }
    }
}

struct BridgeStatusSnapshot {
    let model: String
    let engine: String
    let acceptsWork: Bool
    let servedRequests: Int
}

struct BridgeActivity: Identifiable {
    let id = UUID()
    let at = Date()
    let summary: String
    let accepted: Bool
}

// MARK: - Token storage

enum BridgeTokenStore {
    private static let service = "com.matha.atlas.bridge"
    private static let account = "inference-bridge-token"

    static func loadOrCreate() -> String {
        if let existing = load(), existing.count >= 32 { return existing }
        return regenerate()
    }

    @discardableResult
    static func regenerate() -> String {
        let token = randomToken()
        save(token)
        return token
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // SecRandom should not fail on iOS; UUIDs keep the bridge usable if it does.
            return (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func save(_ token: String) {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ] as CFDictionary)

        SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: Data(token.utf8)
        ] as CFDictionary, nil)
    }

    private static func load() -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Length-independent comparison so a network peer cannot time its way to the token.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = UInt8(left.count == right.count ? 0 : 1)
        let count = max(left.count, right.count)
        guard count > 0 else { return true }
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= a ^ b
        }
        return difference == 0
    }
}

// MARK: - Network helpers

enum BridgeNetwork {
    /// Best-guess Wi-Fi address to show the operator. Purely informational.
    static func primaryLANAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var fallback: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name != "lo0" else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }

            let address = String(cString: host)
            if name.hasPrefix("en") { return address }
            if fallback == nil { fallback = address }
        }
        return fallback
    }

    /// Loopback, RFC1918, CGNAT and link-local only. Anything routable is refused.
    static func isTrustedPeer(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 4 else { return false }
            if bytes[0] == 127 { return true }
            if bytes[0] == 10 { return true }
            if bytes[0] == 192 && bytes[1] == 168 { return true }
            if bytes[0] == 172 && (16...31).contains(bytes[1]) { return true }
            if bytes[0] == 169 && bytes[1] == 254 { return true }
            return false
        case .ipv6(let address):
            if address.isLoopback || address.isLinkLocal { return true }
            let bytes = [UInt8](address.rawValue)
            guard let leading = bytes.first else { return false }
            // Unique local addresses fc00::/7.
            if leading & 0xFE == 0xFC { return true }
            // IPv4-mapped ::ffff:a.b.c.d — re-check against the v4 rules.
            if bytes.count == 16, bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF,
               let mapped = IPv4Address(Data(bytes[12..<16])) {
                return isTrustedPeer(.hostPort(host: .ipv4(mapped), port: 0))
            }
            return false
        default:
            return false
        }
    }
}
