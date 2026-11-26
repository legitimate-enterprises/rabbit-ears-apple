import Foundation
import Security

/// Where the device token, the last server and its name, and each adult's
/// profile memory live between launches.
public protocol CredentialStore: AnyObject {
    var server: URL? { get set }
    /// What `server` last said it is called.
    var serverName: String? { get set }
    var token: String? { get set }
    /// By `AppModel`'s key for a signed-in adult on a server.
    var profileMemories: [String: ProfileMemory] { get set }
}

/// What this device remembers for one signed-in adult: whether a launch
/// skips Who's watching, and the PIN, for the profile last active here.
public struct ProfileMemory: Codable, Equatable, Sendable {
    public var remember: Bool
    public var skipPin: Bool
    public var lastProfileId: Int64?

    public init(remember: Bool, skipPin: Bool, lastProfileId: Int64? = nil) {
        self.remember = remember
        self.skipPin = skipPin
        self.lastProfileId = lastProfileId
    }
}

/// The token in the login keychain, the server address and profile memory in user defaults.
public final class KeychainCredentialStore: CredentialStore {
    private let service = "enterprises.legitimate.rabbit-ears"
    private let account = "device-token"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var server: URL? {
        get { defaults.url(forKey: "server") }
        set { defaults.set(newValue, forKey: "server") }
    }

    public var serverName: String? {
        get { defaults.string(forKey: "serverName") }
        set { defaults.set(newValue, forKey: "serverName") }
    }

    public var profileMemories: [String: ProfileMemory] {
        get {
            defaults.data(forKey: "profileMemories")
                .flatMap { try? JSONDecoder().decode([String: ProfileMemory].self, from: $0) } ?? [:]
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "profileMemories") }
    }

    public var token: String? {
        get {
            var query = baseQuery
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                let data = result as? Data
            else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            SecItemDelete(baseQuery as CFDictionary)
            guard let newValue else { return }
            SecItemAdd(newItem(newValue) as CFDictionary, nil)
        }
    }

    /// Readable in the background once the device has been unlocked since
    /// boot, and never carried to another device by a backup or migration.
    func newItem(_ token: String) -> [String: Any] {
        var item = baseQuery
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return item
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
