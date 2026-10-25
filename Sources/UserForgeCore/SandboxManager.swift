import Foundation

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// 本機上的一般使用者帳號，不限於本程式建立的
public struct LocalUser: Identifiable, Equatable {
    public let name: String
    public let uid: Int
    public let fullName: String
    public let home: String
    public let isAdmin: Bool
    public let loggedIn: Bool
    /// 目前執行本程式的使用者
    public let isCurrent: Bool

    public var id: String { name }
}

/// 建立沙箱時要套用哪一份範本
public enum TemplateSelection {
    /// 設定裡選的預設範本（沒選就是乾淨環境）
    case selected
    /// 不套用範本
    case clean
    /// 指定範本的名稱或 id
    case template(String)
}

public final class SandboxManager {
    /// 範本資料夾名稱以此開頭，所有刪除動作只會碰這種名稱的資料夾
    public static let templateFolderPrefix = "UserForgeTemplate"
    /// 專案改名前建立的範本資料夾名稱，仍然認得（才能刪除、匯出），新範本不再使用
    private static let legacyTemplateFolderPrefix = "SandboxMacTemplate"

    /// 這些偏好設定讓第一次登入時略過設置嚮導的各個畫面。
    /// 不同版本的 macOS 畫面不同，多寫不存在的項目沒有影響。
    private static let setupAssistantKeys = [
        "DidSeeCloudSetup", "DidSeePrivacy", "DidSeeSiriSetup", "DidSeeAccessibility", "DidSeeScreenTime",
        "DidSeeSyncSetup", "DidSeeSyncSetup2", "DidSeeAppearanceSetup", "DidSeeTrueTone", "DidSeeActivationLock",
        "DidSeeApplePaySetup", "DidSeeiCloudLoginForStorageServices", "DidSeeAvatarSetup", "DidSeeTouchIDSetup",
        "DidSeeIntelligence", "DidSeeWalletSetup", "DidSeeSoftwareUpdate",
    ]

    /// 放在每份範本資料夾裡的自述檔，匯出的壓縮檔因此可以獨立搬到別台 Mac
    private struct TemplateMeta: Codable {
        var formatVersion = 1
        var name: String
        var sourceUser: String
        var sourceGUID: String?
        var savedAt: Date
    }

    private let priv: Privileged
    private let log: (String) -> Void

    public init(adminPassword: String?, log: @escaping (String) -> Void = { print($0) }) {
        self.priv = Privileged(password: adminPassword)
        self.log = log
    }

    // MARK: - 查詢

    func userExists(_ name: String) -> Bool {
        (try? Shell.run("/usr/bin/dscl", [".", "-read", "/Users/\(name)", "UniqueID"]))?.ok ?? false
    }

    func dsclValue(_ name: String, _ key: String) -> String? {
        guard let r = try? Shell.run("/usr/bin/dscl", [".", "-read", "/Users/\(name)", key]), r.ok else { return nil }
        let text = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // 單行為 "Key: value"，多行為 "Key:\n value"
        guard let range = text.range(of: ":") else { return nil }
        return text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func uid(of name: String) -> Int? { dsclValue(name, "UniqueID").flatMap { Int($0) } }

    func isAdmin(_ name: String) -> Bool {
        (try? Shell.run("/usr/sbin/dseditgroup", ["-o", "checkmember", "-m", name, "admin"]))?.ok ?? false
    }

    private func pathExists(_ path: String) throws -> Bool {
        try priv.run(["/bin/test", "-e", path], allowFailure: true).ok
    }

    /// 實際家目錄（以系統記錄為準），查不到就退回 /Users/<name>
    func homePath(of name: String) -> String {
        dsclValue(name, "NFSHomeDirectory") ?? "/Users/\(name)"
    }

    // MARK: - 建立

    /// 建立使用者，可建立任意多個。本程式不會記錄建立過哪些使用者。
    /// `name`、`fullName` 留空就依預設規則：帳號為 前綴+日期（重名才加字母），姓名同帳號。
    @discardableResult
    public func create(name requestedName: String? = nil, fullName requestedFullName: String? = nil,
                       template selection: TemplateSelection = .selected) throws -> String {
        let s = SettingsStore.load()
        guard s.namePrefix.range(of: "^[a-z][a-z0-9]{0,20}$", options: .regularExpression) != nil else {
            throw SandboxError("使用者名稱前綴只能用小寫英數字，且以字母開頭")
        }
        guard !s.password.isEmpty else { throw SandboxError("使用者密碼不能是空的") }

        let custom = requestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = custom.isEmpty ? generateName(prefix: s.namePrefix) : custom
        guard name.range(of: "^[a-z][a-z0-9]{1,30}$", options: .regularExpression) != nil else {
            throw SandboxError("帳號只能用小寫英數字，以字母開頭，長度 2 到 31")
        }
        guard !userExists(name) else { throw SandboxError("帳號 \(name) 已經存在") }
        let fullName = requestedFullName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? name

        // 先確認範本還在，免得建立到一半才失敗
        let template = try resolveTemplate(selection, in: s)
        if let template, !(try pathExists(template.path + "/home")) {
            throw SandboxError("範本「\(template.name)」的資料夾不存在：\(template.path)")
        }

        let parent = try validatedHomeParent(s.effectiveHomeParentDir)
        let home = parent + "/" + name
        guard !(try pathExists(home)) else { throw SandboxError("家目錄 \(home) 已經存在，請換一個帳號或位置") }
        log("建立使用者 \(name)，家目錄 \(home)")
        if parent != "/Users" { try priv.run(["/bin/mkdir", "-p", parent]) }

        var args = [
            "/usr/sbin/sysadminctl", "-addUser", name,
            "-fullName", fullName,
            "-password", s.password,
            "-home", home,
            "-shell", "/bin/zsh",
        ]
        if s.makeAdmin { args.append("-admin") }
        try priv.run(args)
        guard userExists(name) else { throw SandboxError("sysadminctl 沒有回報錯誤，但找不到使用者 \(name)") }

        try ensureHome(name, home: home)

        if let template {
            try applyTemplate(template, to: name, home: home)
        } else {
            log("使用乾淨環境")
        }
        if s.skipSetupAssistant { try skipSetupAssistant(for: name, home: home) }
        try applyTweaks(s.tweaks, for: name, home: home)
        log("完成：\(name)，密碼 \(s.password)")
        return name
    }

    // MARK: - 建立時的偏好設定

    /// 把勾選的偏好設定寫進新使用者的 ~/Library/Preferences。項目與值都來自固定的清單並經過檢查，
    /// 路徑與名稱以位置參數傳入，字串不會被當成指令解讀。
    private func applyTweaks(_ chosen: [String: String], for name: String, home: String) throws {
        var triples: [String] = []
        var applied: [String] = []
        for tweak in Tweak.catalog {
            guard let raw = chosen[tweak.id], let value = tweak.normalizedValue(raw) else { continue }
            let type: String
            switch tweak.kind {
            case .bool: type = "bool"
            case .int: type = "int"
            case .choice: type = value.isEmpty ? "delete" : "string"
            }
            triples += [tweak.file, tweak.key, type, value.isEmpty ? "-" : value]
            applied.append(tweak.title)
        }
        guard !triples.isEmpty else { return }
        log("套用偏好設定：" + applied.joined(separator: "、"))

        let script = """
        set -e
        home="$1"; owner="$2"; shift 2
        dir="$home/Library/Preferences"
        mkdir -p "$dir"
        while [ $# -ge 4 ]; do
            file="$dir/$1"
            if [ "$3" = "delete" ]; then
                /usr/bin/defaults delete "$file" "$2" 2>/dev/null || true
            else
                /usr/bin/defaults write "$file" "$2" "-$3" "$4"
            fi
            shift 4
        done
        /usr/sbin/chown -R "$owner:staff" "$dir"
        """
        try priv.run(["/bin/sh", "-c", script, "sh", home, name] + triples)
    }

    private func resolveTemplate(_ selection: TemplateSelection, in s: SandboxSettings) throws -> TemplateRecord? {
        switch selection {
        case .selected: return s.selectedTemplate
        case .clean: return nil
        case .template(let key):
            guard let found = s.templates.first(where: { $0.id == key || $0.name == key }) else {
                throw SandboxError("找不到範本「\(key)」")
            }
            return found
        }
    }

    /// 依目前設定的前綴，回傳下一個預設帳號（給介面當輸入框預設值）
    public func suggestedName() -> String {
        generateName(prefix: SettingsStore.load().namePrefix)
    }

    /// 前綴 + 日期，例如 sandbox20261025；已經有同名帳號才依序加上 a、b…，z 之後接 aa、ab…
    private func generateName(prefix: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        let base = prefix + f.string(from: Date())
        if !userExists(base) { return base }
        var index = 0
        while true {
            let candidate = base + Self.letters(index)
            if !userExists(candidate) { return candidate }
            index += 1
        }
    }

    static func letters(_ index: Int) -> String {
        var n = index
        var result = ""
        repeat {
            result = String(UnicodeScalar(UInt8(97 + n % 26))) + result
            n = n / 26 - 1
        } while n >= 0
        return result
    }

    /// 家目錄的上層資料夾必須是安全的絕對路徑
    private func validatedHomeParent(_ path: String) throws -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        let parts = p.split(separator: "/")
        guard p.hasPrefix("/"), !parts.contains(".."), !parts.contains(".") else {
            throw SandboxError("家目錄位置必須是不含 .. 的絕對路徑：\(path)")
        }
        let forbidden: Set<String> = ["/", "/System", "/Library", "/Applications", "/private", "/usr", "/bin", "/sbin", "/etc", "/var", "/tmp", "/Volumes"]
        guard !forbidden.contains(p) else { throw SandboxError("不能把家目錄放在 \(p) 底下") }
        return p
    }

    /// 刪除家目錄前的最後檢查：路徑最後一段必須剛好是帳號，且不能落在系統目錄
    private func isSafeToRemoveHome(_ home: String, name: String) -> Bool {
        let parts = home.split(separator: "/").map(String.init)
        guard home.hasPrefix("/"), parts.count >= 2, parts.last == name, !parts.contains(".."),
              name.range(of: "^[a-z][a-z0-9]+$", options: .regularExpression) != nil
        else { return false }
        let protected: Set<String> = ["System", "Library", "Applications", "private", "usr", "bin", "sbin", "etc", "var"]
        return !protected.contains(parts[0])
    }

    private func ensureHome(_ name: String, home: String) throws {
        if !(try pathExists(home)) {
            log("建立家目錄")
            try priv.run(["/usr/sbin/createhomedir", "-c", "-u", name], allowFailure: true)
        }
        guard try pathExists(home) else { throw SandboxError("家目錄 \(home) 建立失敗") }
        try priv.run(["/usr/sbin/chown", name + ":staff", home])
    }

    // MARK: - 略過設置嚮導

    /// 寫入 com.apple.SetupAssistant 偏好設定，並把「上次看過的系統版本」設成目前版本，
    /// 否則設置嚮導會因為版本不同而再出現。範本還原後也要重做，因為範本裡的版本可能較舊。
    private func skipSetupAssistant(for name: String, home: String) throws {
        func systemValue(_ flag: String) -> String {
            let text = (try? Shell.run("/usr/bin/sw_vers", [flag]))?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.range(of: "^[0-9A-Za-z.]+$", options: .regularExpression) != nil ? text : ""
        }
        let version = systemValue("-productVersion")
        let build = systemValue("-buildVersion")
        log("略過設置嚮導（系統 \(version) \(build)）")

        // 路徑與名稱以位置參數傳入，避免字串被當成指令解讀
        let script = """
        set -e
        P="$1/Library/Preferences/com.apple.SetupAssistant"
        mkdir -p "$1/Library/Preferences"
        for key in \(Self.setupAssistantKeys.joined(separator: " ")); do
            /usr/bin/defaults write "$P" "$key" -bool true
        done
        /usr/bin/defaults write "$P" GestureMovieSeen -string none
        if [ -n "$3" ]; then /usr/bin/defaults write "$P" LastSeenCloudProductVersion -string "$3"; fi
        if [ -n "$4" ]; then /usr/bin/defaults write "$P" LastSeenBuddyBuildVersion -string "$4"; fi
        /usr/sbin/chown "$2:staff" "$1/Library/Preferences" "$P.plist"
        /bin/chmod 600 "$P.plist"
        """
        try priv.run(["/bin/sh", "-c", script, "sh", home, name, version, build])
    }

    // MARK: - 範本還原

    private func applyTemplate(_ template: TemplateRecord, to name: String, home: String) throws {
        log("還原範本「\(template.name)」（來源 \(template.sourceUser)）")
        try copyHome(from: template.path + "/home", sourceGUID: template.sourceGUID, to: name, home: home)
    }

    /// 把一份家目錄內容複製到某個使用者的家目錄（同名檔案會被覆蓋，多出來的檔案不會被刪除），
    /// 供「套用範本」與「複製使用者」共用。
    private func copyHome(from srcHome: String, sourceGUID: String?, to name: String, home: String,
                          removeJunk: Bool = false) throws {
        try priv.run(["/usr/bin/ditto", srcHome, home])
        if removeJunk {
            for junk in ["Library/Caches", "Library/Logs", ".Trash"] {
                try priv.run(["/bin/rm", "-rf", "\(home)/\(junk)"])
            }
        }

        // 資料保護鑰匙圈以使用者的 GeneratedUID 命名，換使用者後要改名才讀得到
        if let oldGUID = sourceGUID, let newGUID = dsclValue(name, "GeneratedUID"), oldGUID != newGUID {
            let oldKC = "\(home)/Library/Keychains/\(oldGUID)"
            let newKC = "\(home)/Library/Keychains/\(newGUID)"
            if try pathExists(oldKC) {
                try priv.run(["/bin/rm", "-rf", newKC])
                try priv.run(["/bin/mv", oldKC, newKC])
                log("已把鑰匙圈資料夾改為新使用者的識別碼")
            }
        }
        try priv.run(["/usr/sbin/chown", "-R", "\(name):staff", home])
    }

    // MARK: - 任意使用者：列出、複製、還原

    /// 本機上的一般使用者帳號（排除系統帳號），不限於本程式建立的
    public func localUsers() -> [LocalUser] {
        guard let result = try? Shell.run("/usr/bin/dscl", [".", "-list", "/Users", "UniqueID"]), result.ok else { return [] }
        var users: [LocalUser] = []
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 2, let uid = Int(parts[1]) else { continue }
            let name = String(parts[0])
            guard uid >= 500, !name.hasPrefix("_") else { continue }
            users.append(LocalUser(
                name: name, uid: uid,
                fullName: dsclValue(name, "RealName") ?? name,
                home: homePath(of: name),
                isAdmin: isAdmin(name),
                loggedIn: isLoggedIn(uid: uid),
                isCurrent: name == NSUserName()))
        }
        return users.sorted { $0.uid < $1.uid }
    }

    /// 有桌面工作階段的使用者一定有 Dock 程序，不需要 root 就能查
    func isLoggedIn(uid: Int) -> Bool {
        (try? Shell.run("/usr/bin/pgrep", ["-u", String(uid), "-x", "Dock"]))?.ok ?? false
    }

    /// 確認是一般使用者帳號（備份、複製、還原的對象不限於本程式建立的）
    @discardableResult
    private func requireLocalUser(_ name: String) throws -> Int {
        guard userExists(name), let uid = uid(of: name), uid >= 500, !name.hasPrefix("_") else {
            throw SandboxError("\(name) 不存在，或不是一般使用者帳號")
        }
        return uid
    }

    /// 把現有使用者（任何帳號）複製成一個新使用者：建立新帳號後，把來源家目錄的內容複製過去。
    /// 來源正在登入時檔案可能還在變動，建議先登出。
    @discardableResult
    public func cloneUser(from source: String, name requestedName: String? = nil,
                          fullName requestedFullName: String? = nil) throws -> String {
        let sourceUID = try requireLocalUser(source)
        let srcHome = homePath(of: source)
        guard try pathExists(srcHome) else { throw SandboxError("來源使用者的家目錄不存在：\(srcHome)") }
        if isLoggedIn(uid: sourceUID) {
            log("⚠︎ \(source) 目前登入中，複製期間檔案可能仍在變動，建議先登出")
        }

        let name = try create(name: requestedName, fullName: requestedFullName, template: .clean)
        let home = homePath(of: name)
        log("複製 \(source) 的家目錄 → \(home)（依大小可能需要一些時間）")
        try copyHome(from: srcHome, sourceGUID: dsclValue(source, "GeneratedUID"), to: name, home: home, removeJunk: true)
        let s = SettingsStore.load()
        if s.skipSetupAssistant { try skipSetupAssistant(for: name, home: home) }
        try applyTweaks(s.tweaks, for: name, home: home)
        log("已把 \(source) 複製為 \(name)。若來源與新使用者的密碼不同，複製過來的登入鑰匙圈需要用來源的密碼解鎖")
        return name
    }

    /// 把範本還原到一個現有的使用者：同名檔案會被覆蓋，多出來的檔案不會被刪除。
    /// 對象必須已登出，因為登入中的程式會把舊設定寫回去。
    public func restoreTemplate(_ key: String, to name: String) throws {
        let s = SettingsStore.load()
        guard let template = s.templates.first(where: { $0.id == key || $0.name == key }) else {
            throw SandboxError("找不到範本「\(key)」")
        }
        guard try pathExists(template.path + "/home") else {
            throw SandboxError("範本資料夾不存在：\(template.path)")
        }
        let uid = try requireLocalUser(name)
        guard !isLoggedIn(uid: uid) else {
            throw SandboxError("使用者 \(name) 目前登入中，請先登出再還原")
        }
        let home = homePath(of: name)
        guard try pathExists(home) else { throw SandboxError("家目錄不存在：\(home)") }
        log("把範本「\(template.name)」還原到 \(name)（會覆蓋同名檔案）")
        try copyHome(from: template.path + "/home", sourceGUID: template.sourceGUID, to: name, home: home)
        log("已還原到 \(name)")
    }

    // MARK: - 範本管理

    /// 預設的範本名稱：來源帳號加上時間
    public static func suggestedTemplateName(sourceUser: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(sourceUser) \(f.string(from: Date()))"
    }

    /// 把指定使用者（任何一般帳號）的家目錄備份成範本。同一個帳號可以存很多份，只有同名才會覆蓋。
    /// `deleteUser` 為 true 時備份後刪除該使用者（套用與一般刪除相同的保護）。
    public func saveTemplate(from name: String, as requestedName: String? = nil, deleteUser: Bool = false) throws {
        var s = SettingsStore.load()
        let uid = try requireLocalUser(name)
        // 要刪除的話，備份開始前就先確認能刪，免得備份完才發現不行
        if deleteUser { try requireDeletable(name) }

        let templateName = requestedName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? Self.suggestedTemplateName(sourceUser: name)
        let existing = s.templates.first { $0.name == templateName }
        let id = existing?.id ?? String(UUID().uuidString.prefix(8)).lowercased()

        let base = s.effectiveTemplateBaseDir
        guard base.hasPrefix("/"), !base.split(separator: "/").contains("..") else {
            throw SandboxError("範本目錄必須是絕對路徑：\(base)")
        }
        let home = homePath(of: name)
        guard base != home, !base.hasPrefix(home + "/") else {
            throw SandboxError("範本目錄不能放在要備份的使用者家目錄裡")
        }
        let final = "\(base)/\(Self.templateFolderPrefix)-\(id)"
        let staging = final + ".new"

        // 備份後要刪除的使用者才強制登出（反正即將消失）；其他帳號不結束它的程序，只提醒
        if deleteUser {
            log("登出 \(name) 並結束它的程序")
            try logout(name)
        } else if isLoggedIn(uid: uid) {
            log("⚠︎ \(name) 目前登入中，備份期間檔案可能仍在變動（資料庫、偏好設定可能還沒寫入），建議先登出")
        }

        log("備份 \(home) → \(final)")
        try priv.run(["/bin/mkdir", "-p", base])
        try priv.run(["/bin/rm", "-rf", staging])
        try priv.run(["/bin/mkdir", "-p", staging])
        try priv.run(["/usr/bin/ditto", home, staging + "/home"])
        for junk in ["Library/Caches", "Library/Logs", ".Trash"] {
            try priv.run(["/bin/rm", "-rf", "\(staging)/home/\(junk)"])
        }
        var record = TemplateRecord(
            id: id, name: templateName, path: final, savedAt: Date(), sourceUser: name,
            sourceGUID: dsclValue(name, "GeneratedUID"), sizeBytes: nil)
        try writeMeta(record, in: staging)
        try priv.run(["/bin/chmod", "700", staging])

        // 新範本完整備份成功後，才移除被覆蓋的舊內容
        if let old = existing, old.path != final { try removeTemplateFolder(old.path) }
        try priv.run(["/bin/rm", "-rf", final])
        try priv.run(["/bin/mv", staging, final])

        record.sizeBytes = try? measure(final)
        s = SettingsStore.load()
        if let index = s.templates.firstIndex(where: { $0.id == id }) {
            s.templates[index] = record
        } else {
            s.templates.append(record)
        }
        s.selectedTemplateID = id
        SettingsStore.save(s)
        log("範本「\(templateName)」已儲存" + (record.sizeBytes.map { "，佔用 \(Self.formatBytes($0))" } ?? ""))

        if deleteUser { try delete(name: name) }
    }

    // MARK: - 匯出與匯入

    private func writeMeta(_ template: TemplateRecord, in folder: String) throws {
        let meta = TemplateMeta(name: template.name, sourceUser: template.sourceUser,
                                sourceGUID: template.sourceGUID, savedAt: template.savedAt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // 範本資料夾只有 root 寫得進去，所以先寫到暫存檔再用 root 複製
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("userforge-\(UUID().uuidString).json")
        try encoder.encode(meta).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        try priv.run(["/bin/cp", temp.path, folder + "/template.json"])
        try priv.run(["/bin/chmod", "600", folder + "/template.json"])
    }

    /// 把範本壓縮成單一 zip 檔。壓縮檔包含完整的家目錄備份，可能有密碼、金鑰等敏感資料，請妥善保管。
    public func exportTemplate(_ key: String, to destination: String) throws {
        let s = SettingsStore.load()
        guard let template = s.templates.first(where: { $0.id == key || $0.name == key }) else {
            throw SandboxError("找不到範本「\(key)」")
        }
        guard destination.hasPrefix("/"), !destination.split(separator: "/").contains("..") else {
            throw SandboxError("匯出路徑必須是不含 .. 的絕對路徑")
        }
        guard try pathExists(template.path + "/home") else {
            throw SandboxError("範本資料夾不存在：\(template.path)")
        }
        try writeMeta(template, in: template.path)

        // 目的地已存在表示使用者在存檔對話框確認過要取代
        try? FileManager.default.removeItem(atPath: destination)
        log("壓縮範本「\(template.name)」→ \(destination)（依大小可能需要一些時間）")
        try priv.run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", template.path, destination])
        if geteuid() != 0 { try priv.run(["/usr/sbin/chown", NSUserName(), destination]) }
        try priv.run(["/bin/chmod", "600", destination])

        let size = (try? FileManager.default.attributesOfItem(atPath: destination)[.size] as? Int64) ?? nil
        log("已匯出" + (size.map { "，壓縮檔 \(Self.formatBytes($0))" } ?? "") + "。檔案內含完整家目錄，請妥善保管")
    }

    /// 從 zip 匯入範本。只匯入你信任的檔案：範本裡的內容會原樣還原到沙箱，包含自動啟動的程式。
    @discardableResult
    public func importTemplate(from source: String) throws -> TemplateRecord {
        guard source.hasPrefix("/"), FileManager.default.fileExists(atPath: source) else {
            throw SandboxError("找不到檔案：\(source)")
        }
        // 先檢查壓縮檔內的路徑，擋掉絕對路徑與 .. 這類想跳出資料夾的項目
        let listing = try Shell.run("/usr/bin/zipinfo", ["-1", source])
        guard listing.ok else { throw SandboxError("不是有效的 zip 檔：\(listing.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
        for entry in listing.stdout.split(separator: "\n") {
            if entry.hasPrefix("/") || entry.split(separator: "/").contains("..") {
                throw SandboxError("壓縮檔含有不安全的路徑，拒絕匯入：\(entry)")
            }
        }

        // 用目前使用者的權限解壓縮，惡意壓縮檔最多只能寫入使用者本來就能寫的地方；
        // 之後才由 root 搬進範本資料夾
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("userforge-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        log("解壓縮 \(source)")
        let extract = try Shell.run("/usr/bin/ditto", ["-x", "-k", source, staging.path])
        guard extract.ok else { throw SandboxError("解壓縮失敗：\(extract.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }

        let tops = (try FileManager.default.contentsOfDirectory(atPath: staging.path)).filter { $0 != "__MACOSX" && !$0.hasPrefix(".") }
        guard tops.count == 1 else { throw SandboxError("壓縮檔結構不正確，不是本程式匯出的範本") }
        let top = staging.appendingPathComponent(tops[0])
        let homeType = (try? FileManager.default.attributesOfItem(atPath: top.appendingPathComponent("home").path))?[.type] as? FileAttributeType
        guard homeType == .typeDirectory else { throw SandboxError("壓縮檔裡沒有 home 資料夾，不是本程式匯出的範本") }

        var meta: TemplateMeta?
        if let data = try? Data(contentsOf: top.appendingPathComponent("template.json")) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            meta = try? decoder.decode(TemplateMeta.self, from: data)
        }

        var s = SettingsStore.load()
        // 名稱重複時加上編號，不覆蓋既有範本
        let baseName = (meta?.name).flatMap { $0.nilIfEmpty }
            ?? URL(fileURLWithPath: source).deletingPathExtension().deletingPathExtension().lastPathComponent
        var templateName = baseName
        var counter = 2
        while s.templates.contains(where: { $0.name == templateName }) {
            templateName = "\(baseName) \(counter)"
            counter += 1
        }

        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let base = s.effectiveTemplateBaseDir
        guard base.hasPrefix("/"), !base.split(separator: "/").contains("..") else {
            throw SandboxError("範本目錄必須是絕對路徑：\(base)")
        }
        let final = "\(base)/\(Self.templateFolderPrefix)-\(id)"
        let incoming = final + ".new"

        log("匯入為範本「\(templateName)」→ \(final)")
        try priv.run(["/bin/mkdir", "-p", base])
        try priv.run(["/bin/rm", "-rf", incoming])
        try priv.run(["/usr/bin/ditto", top.path, incoming])
        try priv.run(["/usr/sbin/chown", "root:wheel", incoming])
        try priv.run(["/bin/chmod", "700", incoming])
        try priv.run(["/bin/mv", incoming, final])

        var record = TemplateRecord(
            id: id, name: templateName, path: final, savedAt: meta?.savedAt ?? Date(),
            sourceUser: meta?.sourceUser ?? "匯入", sourceGUID: meta?.sourceGUID, sizeBytes: nil)
        try writeMeta(record, in: final)
        record.sizeBytes = try? measure(final)

        s = SettingsStore.load()
        s.templates.append(record)
        SettingsStore.save(s)
        log("範本「\(templateName)」已匯入" + (record.sizeBytes.map { "，佔用 \(Self.formatBytes($0))" } ?? ""))
        return record
    }

    public func deleteTemplate(_ key: String) throws {
        var s = SettingsStore.load()
        guard let template = s.templates.first(where: { $0.id == key || $0.name == key }) else {
            throw SandboxError("找不到範本「\(key)」")
        }
        try removeTemplateFolder(template.path)
        try removeTemplateFolder(template.path + ".new")
        s.templates.removeAll { $0.id == template.id }
        if s.selectedTemplateID == template.id { s.selectedTemplateID = nil }
        SettingsStore.save(s)
        log("已刪除範本「\(template.name)」")
    }

    public func deleteAllTemplates() throws {
        for template in SettingsStore.load().templates { try deleteTemplate(template.id) }
    }

    public func renameTemplate(_ key: String, to newName: String) throws {
        var s = SettingsStore.load()
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SandboxError("範本名稱不能是空的") }
        guard let index = s.templates.firstIndex(where: { $0.id == key || $0.name == key }) else {
            throw SandboxError("找不到範本「\(key)」")
        }
        guard !s.templates.contains(where: { $0.name == name && $0.id != s.templates[index].id }) else {
            throw SandboxError("已經有名為「\(name)」的範本")
        }
        s.templates[index].name = name
        SettingsStore.save(s)
    }

    /// 範本資料夾只有 root 讀得到，所以用 du 量測實際佔用的磁碟空間
    private func measure(_ path: String) throws -> Int64 {
        let result = try priv.run(["/usr/bin/du", "-sk", path])
        guard let kilobytes = result.stdout.split(whereSeparator: \.isWhitespace).first.flatMap({ Int64($0) }) else {
            throw SandboxError("無法解析 du 的輸出：\(result.stdout)")
        }
        return kilobytes * 1024
    }

    /// 重新計算範本大小並記錄；不指定就全部重算
    public func refreshTemplateSize(_ key: String? = nil) throws {
        var s = SettingsStore.load()
        for index in s.templates.indices where key == nil || s.templates[index].id == key || s.templates[index].name == key {
            let template = s.templates[index]
            guard try pathExists(template.path) else {
                log("找不到範本「\(template.name)」的資料夾：\(template.path)")
                continue
            }
            let size = try measure(template.path)
            s.templates[index].sizeBytes = size
            log("範本「\(template.name)」佔用 \(Self.formatBytes(size))")
        }
        SettingsStore.save(s)
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// 只刪除名稱符合的範本資料夾，避免設定檔被改壞時刪到別的地方
    private func removeTemplateFolder(_ path: String) throws {
        let last = URL(fileURLWithPath: path).lastPathComponent
        let looksLikeTemplate = last.hasPrefix(Self.templateFolderPrefix) || last.hasPrefix(Self.legacyTemplateFolderPrefix)
            || path == "/Users/Shared/SandboxMac/template"
        guard path.hasPrefix("/"), looksLikeTemplate else {
            throw SandboxError("拒絕刪除看起來不是範本的路徑：\(path)")
        }
        try priv.run(["/bin/rm", "-rf", path])
    }

    // MARK: - 刪除

    /// 刪除一般使用者與它的家目錄，不論是不是本程式建立的（本程式不記錄建立過哪些使用者）。
    /// 沒有批次刪除，每次只刪一個。
    public func delete(name: String) throws {
        try requireDeletable(name)
        let home = homePath(of: name)

        log("刪除使用者 \(name)")
        try logout(name)
        try priv.run(["/usr/sbin/sysadminctl", "-deleteUser", name], allowFailure: true)
        if userExists(name) { throw SandboxError("使用者 \(name) 刪除失敗") }

        // sysadminctl 通常已經一併刪除；殘留的話只清除路徑最後一段剛好是這個帳號的家目錄，避免路徑被誤用
        if isSafeToRemoveHome(home, name: name), try pathExists(home) {
            try priv.run(["/bin/rm", "-rf", home])
        }
        log("已刪除 \(name)")
    }

    /// 刪除前的保護：一般帳號、不是正在執行本程式的人、不能刪掉最後一個管理員
    private func requireDeletable(_ name: String) throws {
        try requireLocalUser(name)
        guard name != NSUserName() else { throw SandboxError("不能刪除目前執行本程式的使用者 \(name)") }
        if isAdmin(name), !localUsers().contains(where: { $0.name != name && $0.isAdmin }) {
            throw SandboxError("\(name) 是最後一個管理員帳號，刪除後這台電腦就沒有管理員了")
        }
    }

    private func logout(_ name: String) throws {
        guard let uid = uid(of: name) else { return }
        try priv.run(["/bin/launchctl", "bootout", "gui/\(uid)"], allowFailure: true)
        try priv.run(["/bin/launchctl", "bootout", "user/\(uid)"], allowFailure: true)
        try priv.run(["/usr/bin/pkill", "-KILL", "-u", String(uid)], allowFailure: true)
        Thread.sleep(forTimeInterval: 1.5)
    }
}
