import Foundation
import Security

public struct DispatchPairingConfiguration: Equatable, Sendable {
    public var relayBaseURL: String
    public var roomID: String
    public var bearerToken: String

    public init(relayBaseURL: String, roomID: String, bearerToken: String) {
        self.relayBaseURL = relayBaseURL
        self.roomID = roomID
        self.bearerToken = bearerToken
    }

    public var socketURL: URL? {
        let trimmed = relayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let room = roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !room.isEmpty else { return nil }
        if trimmed.hasSuffix("/connect") { return URL(string: trimmed) }
        return URL(string: "\(trimmed)/v1/rooms/\(room)/connect")
    }
}

public enum DispatchPairing {
    private static let relayKey = "localGemma.dispatch.relayBaseURL"
    private static let roomKey = "localGemma.dispatch.roomID"
    private static let keychainService = "com.matha.atlas.Dispatch"
    private static let keychainAccount = "relayBearerToken"

    public static func current() -> DispatchPairingConfiguration? {
        guard let relay = UserDefaults.standard.string(forKey: relayKey),
              let room = UserDefaults.standard.string(forKey: roomKey),
              let token = readToken(),
              !relay.isEmpty, !room.isEmpty, !token.isEmpty else { return nil }
        return DispatchPairingConfiguration(relayBaseURL: relay, roomID: room, bearerToken: token)
    }

    @discardableResult
    public static func save(_ configuration: DispatchPairingConfiguration) -> Bool {
        guard configuration.socketURL != nil,
              !configuration.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        UserDefaults.standard.set(configuration.relayBaseURL, forKey: relayKey)
        UserDefaults.standard.set(configuration.roomID, forKey: roomKey)
        return writeToken(configuration.bearerToken)
    }

    @discardableResult
    public static func accept(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "mathaatlas",
              url.host?.lowercased() == "dispatch-pair",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let values = Dictionary(uniqueKeysWithValues: components.queryItems?.compactMap { item in
            item.value.map { (item.name, $0) }
        } ?? [])
        guard let relay = values["relay"],
              let room = values["room"],
              let token = values["token"] else { return false }
        return save(DispatchPairingConfiguration(relayBaseURL: relay, roomID: room, bearerToken: token))
    }

    public static func clear() {
        UserDefaults.standard.removeObject(forKey: relayKey)
        UserDefaults.standard.removeObject(forKey: roomKey)
        SecItemDelete(keychainQuery as CFDictionary)
    }

    private static var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
    }

    private static func writeToken(_ token: String) -> Bool {
        SecItemDelete(keychainQuery as CFDictionary)
        var query = keychainQuery
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func readToken() -> String? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
