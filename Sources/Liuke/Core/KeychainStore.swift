import Foundation
import Security

/// 轻量 Keychain 封装：按 key 存 / 取 / 删字符串。
/// 用于保存各模型的 API Key，避免明文写入 config.json 等业务数据文件。
///
/// **写入方式（v3 定稿，2026-08-13 实验验证）**：
/// - `kSecAttrAccessibleAfterFirstUnlock` + **`kSecAttrAccess`（SecAccess 空信任列表）**：
///   空 trustedApplications = 允许**任何**应用访问，ACL 不绑定 app 签名。
///   任何进程（包括每次 ad-hoc 重签后的 .app）读取都**不会触发 macOS 授权弹窗**。
/// - ⚠️ 不用 `kSecAttrAccessControl`：实测需要 keychain-access-groups entitlement
///   （errSecMissingEntitlement -34018），app 没有该 entitlement，写入会静默失败。
/// - 服务名用 `.v3`：v1/v2 里的旧项绑定了更早 build 的代码签名，**永不访问**
///   （枚举/读取它们正是 macOS 弹窗"security 想要使用钥匙串中的机密信息"的根源）。
final class KeychainStore {

    static let shared = KeychainStore()

    /// 留刻专属服务名（v3：宽松 ACL，任何签名可读，零弹窗）
    private let service = "app.memento.lens.v3"

    /// 写入（已存在则覆盖）。update 只更新值；add 带宽松 ACL。
    func set(_ value: String, forKey key: String) {
        let data = Data(value.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        // 1) 已存在 → 只更新值（ACL 保持创建时的宽松状态）
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary,
                                         [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        // 2) 不存在 → 新建（宽松 ACL：允许任何应用，杜绝授权弹窗）
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        // 空 trustedApplications = 允许任何应用访问（任何签名、任何进程，零弹窗）
        var access: SecAccess?
        if SecAccessCreate("liuke-keys" as CFString, [] as CFArray, &access) == errSecSuccess,
           let access {
            addQuery[kSecAttrAccess as String] = access
        }
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            Log.shared.error("keychain add failed: \(status)")
        }
    }

    /// 读取（不存在返回 nil）。非绑定 ACL，重签不影响读取，零弹窗。
    func get(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 删除（不存在返回 false）
    @discardableResult
    func delete(forKey key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    /// 找回遗留的模型 key：枚举本服务（v2）下所有项，返回第一个非空值。
    /// ⚠️ 不查旧 .v1 服务 —— 旧项绑定了更早 build 的代码签名，枚举会触发 macOS 授权弹窗。
    func recoverOrphanedKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        let items = item as? [[String: Any]] ?? []
        for dict in items {
            if let data = dict[kSecValueData as String] as? Data,
               let val = String(data: data, encoding: .utf8), !val.isEmpty {
                return val
            }
        }
        return nil
    }
}
