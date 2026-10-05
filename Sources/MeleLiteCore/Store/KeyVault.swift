import Foundation
import Security

/// 模型 key 放哪：正式用钥匙串，测试和预览用内存。key 从不进导出文件。
public protocol KeyVault: AnyObject, Sendable {
    func get(_ provider: String) -> String?
    func set(_ key: String?, for provider: String)
}

public final class MemoryVault: KeyVault, @unchecked Sendable {
    private var keys: [String: String] = [:]
    private let lock = NSLock()
    public init() {}
    public func get(_ provider: String) -> String? { lock.withLock { keys[provider] } }
    public func set(_ key: String?, for provider: String) { lock.withLock { keys[provider] = key } }
}

public final class KeychainVault: KeyVault, @unchecked Sendable {
    let service: String
    public init(service: String = "app.melelite.keys") { self.service = service }

    private func query(_ provider: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: provider]
    }

    public func get(_ provider: String) -> String? {
        var q = query(provider)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ key: String?, for provider: String) {
        SecItemDelete(query(provider) as CFDictionary)
        guard let key, !key.isEmpty else { return }
        var q = query(provider)
        q[kSecValueData as String] = Data(key.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}
