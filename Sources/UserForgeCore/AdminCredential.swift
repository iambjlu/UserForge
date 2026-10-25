import Foundation
import Security

/// 把管理員密碼存在登入鑰匙圈，只需要輸入一次。
public enum AdminCredential {
    private static let service = "local.userforge.admin"
    /// 專案改名前使用的項目名稱，讀不到新項目時會改讀這個，並自動搬到新項目
    private static let legacyService = "local.sandboxmac.admin"
    private static var account: String { NSUserName() }

    private static func baseQuery(_ service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func read(_ service: String) -> String? {
        var query = baseQuery(service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public static func load() -> String? {
        if let password = read(service) { return password }
        guard let legacy = read(legacyService) else { return nil }
        // 舊項目搬到新項目；寫入失敗（例如沒有圖形工作階段）就保留舊項目，下次再試
        if (try? save(legacy)) != nil { SecItemDelete(baseQuery(legacyService) as CFDictionary) }
        return legacy
    }

    public static func save(_ password: String) throws {
        delete()
        var attributes = baseQuery(service)
        attributes[kSecValueData as String] = Data(password.utf8)
        attributes[kSecAttrLabel as String] = "UserForge 管理員密碼"
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw SandboxError("無法寫入鑰匙圈 (OSStatus \(status))") }
    }

    public static func delete() {
        SecItemDelete(baseQuery(service) as CFDictionary)
        SecItemDelete(baseQuery(legacyService) as CFDictionary)
    }

    /// 用 sudo 驗證密碼是否正確（密碼只經由 stdin 傳遞）
    public static func verify(_ password: String) -> Bool {
        if geteuid() == 0 { return true }
        guard !password.isEmpty,
              let result = try? Shell.run("/usr/bin/sudo", ["-k", "-S", "-p", "", "-v"], input: password + "\n")
        else { return false }
        return result.ok
    }
}
