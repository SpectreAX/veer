import CryptoKit
import Foundation
import Security

/// One saved editor session. `state` is the app's own encoding of the
/// conversation and draft; the store treats it as opaque bytes.
public struct StoredSession: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var subtitle: String
    public var hasUnexportedChanges: Bool
    public var updatedAt: Date
    public var state: Data
    public init(id: UUID, name: String, subtitle: String, hasUnexportedChanges: Bool, updatedAt: Date, state: Data) {
        self.id = id; self.name = name; self.subtitle = subtitle
        self.hasUnexportedChanges = hasUnexportedChanges; self.updatedAt = updatedAt; self.state = state
    }
}

public protocol SessionKeyProvider: Sendable {
    func key() throws -> SymmetricKey
}

/// A random 256-bit key kept in the login keychain, readable only on this device.
public struct KeychainSessionKey: SessionKeyProvider {
    private let service: String
    private let account = "sessions-v1"
    public init(service: String = "com.yamax.veer.editor.sessions") { self.service = service }

    public func key() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound else { throw EditorFailure("无法读取会话加密密钥（钥匙串错误 \(status)）。请解锁钥匙串后重试。") }
        let key = SymmetricKey(size: .bits256)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Veer 编辑器会话密钥", kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: key.withUnsafeBytes { Data($0) },
        ]
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw EditorFailure("无法保存会话加密密钥（钥匙串错误 \(added)）。会话将只保留在内存中。") }
        return key
    }
}

/// Sessions hold full imported configurations, including node credentials, so
/// they are written only as AES-GCM ciphertext with owner-only permissions.
public final class SessionStore: @unchecked Sendable {
    private let url: URL
    private let keyProvider: any SessionKeyProvider
    private static let magic = Data("VEERSES1".utf8)

    public init(url: URL, keyProvider: any SessionKeyProvider = KeychainSessionKey()) {
        self.url = url
        self.keyProvider = keyProvider
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Veer/Editor/sessions.bin")
    }

    public func load() throws -> [StoredSession] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let file = try Data(contentsOf: url)
        guard file.starts(with: Self.magic) else { throw EditorFailure("会话文件格式无法识别，已保留原文件。") }
        do {
            let box = try AES.GCM.SealedBox(combined: file.dropFirst(Self.magic.count))
            let plain = try AES.GCM.open(box, using: try keyProvider.key())
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([StoredSession].self, from: plain)
        } catch let failure as EditorFailure { throw failure }
        catch { throw EditorFailure("无法解密已保存的会话。可能是钥匙串密钥已更换；原文件已保留。") }
    }

    public func save(_ sessions: [StoredSession]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plain = try encoder.encode(sessions)
        guard let sealed = try AES.GCM.seal(plain, using: try keyProvider.key()).combined else { throw EditorFailure("会话加密失败。") }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try (Self.magic + sealed).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Move an unreadable file aside so new sessions can be saved without destroying it.
    public func quarantine() throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).bin")
        try FileManager.default.moveItem(at: url, to: aside)
        return aside
    }
}
