import Foundation
import Security

/// Secrets as generic passwords in the login keychain, one per account, kept on this Mac. The data
/// protection keychain would need a provisioning profile for its access group, which Veer has not.
public final class KeychainKeyStore: KeyStoring, @unchecked Sendable {
    public static let defaultService = "com.yamax.veer.secrets"
    public let service: String

    public init(service: String = KeychainKeyStore.defaultService) { self.service = service }

    private func query(for account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func read(for provider: String) -> String? {
        var request = query(for: provider)
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ key: String, for provider: String) throws {
        let value = Data(key.utf8)
        var status = SecItemUpdate(query(for: provider) as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(for: provider)
            item[kSecValueData as String] = value
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? String(status)
            throw EditorError(String(localized: "无法保存 API Key：\(message)"))
        }
    }

    public func delete(for provider: String) {
        SecItemDelete(query(for: provider) as CFDictionary)
    }
}

/// `store`, plus whatever is still waiting to leave an older file. An entry leaves the file only
/// once it reads back the same from `store`, so a keychain that refuses loses nothing: the entry
/// stays in the file, is still read from there, and moves at the next launch.
public final class MigratingKeyStore: KeyStoring, @unchecked Sendable {
    private let store: KeyStoring
    private let legacy: FileKeyStore
    private let lock = NSLock()
    /// Pages ask for keys while they draw, and each read of the keychain goes to another process.
    private var cache: [String: String?] = [:]

    public init(store: KeyStoring, legacy: FileKeyStore) {
        self.store = store
        self.legacy = legacy
        let moved = legacy.all().filter { account, value in
            do { try store.save(value, for: account) } catch { return false }
            return store.read(for: account) == value
        }
        legacy.delete(moved.keys)
    }

    public func read(for provider: String) -> String? {
        lock.withLock {
            if let known = cache[provider] { return known }
            let value = store.read(for: provider) ?? legacy.read(for: provider)
            cache[provider] = .some(value)
            return value
        }
    }

    public func save(_ key: String, for provider: String) throws {
        try lock.withLock {
            try store.save(key, for: provider)
            legacy.delete(for: provider)
            cache[provider] = .some(key)
        }
    }

    public func delete(for provider: String) {
        lock.withLock {
            store.delete(for: provider)
            legacy.delete(for: provider)
            cache[provider] = .some(nil)
        }
    }
}
