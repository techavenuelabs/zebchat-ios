import Foundation
import Security

/// Where the SDK keeps the visitor key and session. The Keychain in apps; a mock in tests.
protocol SecureStore: AnyObject {
    func data(forKey key: String) -> Data?
    /// Stores `data`, or deletes the entry for `nil`.
    func set(_ data: Data?, forKey key: String)
}

/// Generic-password Keychain items, readable after the first unlock and never migrated to
/// another device (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
final class KeychainStore: SecureStore, @unchecked Sendable {
    private let service: String
    private let lock = NSLock()

    init(service: String) {
        self.service = service
    }

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    func data(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound { Log.error("Keychain read failed (\(status))") }
            return nil
        }
        return result as? Data
    }

    func set(_ data: Data?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        let item = query(key)
        guard let data else {
            let status = SecItemDelete(item as CFDictionary)
            if status != errSecSuccess, status != errSecItemNotFound {
                Log.error("Keychain delete failed (\(status))")
            }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(item as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let addition = item.merging(attributes) { _, new in new }
            status = SecItemAdd(addition as CFDictionary, nil)
        }
        if status != errSecSuccess { Log.error("Keychain write failed (\(status))") }
    }
}

/// The push token as last registered with `POST /widget/devices`, and for which visitor.
struct RegisteredDevice: Codable, Equatable, Sendable {
    let token: String
    let visitorId: String
}

/// Typed access to the SDK's stored state.
final class SDKState: @unchecked Sendable {
    enum Key {
        static let visitorKey = "visitorKey"
        static let session = "session"
        static let user = "user"
        static let pushToken = "pushToken"
        static let registeredDevice = "registeredDevice"
    }

    private let store: SecureStore

    init(store: SecureStore) {
        self.store = store
    }

    /// The long-lived visitor secret. Never sent to the web view or put in a URL.
    var visitorKey: String? {
        get { string(Key.visitorKey) }
        set { setString(newValue, Key.visitorKey) }
    }

    var session: StoredSession? {
        get { decode(StoredSession.self, Key.session) }
        set { encode(newValue, Key.session) }
    }

    var user: ZebChatUser? {
        get { decode(ZebChatUser.self, Key.user) }
        set { encode(newValue, Key.user) }
    }

    var pushToken: String? {
        get { string(Key.pushToken) }
        set { setString(newValue, Key.pushToken) }
    }

    var registeredDevice: RegisteredDevice? {
        get { decode(RegisteredDevice.self, Key.registeredDevice) }
        set { encode(newValue, Key.registeredDevice) }
    }

    /// `logout()`: forget the visitor and the user. The push token stays (it belongs to the device).
    func clearIdentity() {
        for key in [Key.visitorKey, Key.session, Key.user, Key.registeredDevice] {
            store.set(nil, forKey: key)
        }
    }

    private func string(_ key: String) -> String? {
        store.data(forKey: key).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func setString(_ value: String?, _ key: String) {
        store.set(value.map { Data($0.utf8) }, forKey: key)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = store.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func encode<T: Encodable>(_ value: T?, _ key: String) {
        store.set(value.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
    }
}
