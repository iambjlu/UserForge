import Foundation

/// 一份已儲存的範本（某個使用者家目錄的備份）
public struct TemplateRecord: Codable, Equatable, Identifiable {
    /// 同時是範本資料夾名稱的一部分
    public var id: String
    /// 使用者看到的名稱；同名儲存會覆蓋
    public var name: String
    /// 範本資料夾的完整路徑，之後改了範本目錄設定也不影響既有範本
    public var path: String
    public var savedAt: Date
    public var sourceUser: String
    public var sourceGUID: String?
    /// 佔用的磁碟空間（位元組）
    public var sizeBytes: Int64?

    public init(id: String, name: String, path: String, savedAt: Date, sourceUser: String,
                sourceGUID: String?, sizeBytes: Int64?) {
        self.id = id
        self.name = name
        self.path = path
        self.savedAt = savedAt
        self.sourceUser = sourceUser
        self.sourceGUID = sourceGUID
        self.sizeBytes = sizeBytes
    }
}

public struct SandboxSettings: Codable, Equatable {
    /// 沙箱使用者的登入密碼
    public var password = "0000"
    /// 本機轉發埠（預設 5910）
    public var forwardPort = 5910
    /// 被轉發的來源埠（螢幕共享，預設 5900）
    public var sourcePort = 5900
    /// 使用者名稱前綴，後面接日期與字母
    public var namePrefix = "sandbox"
    /// 沙箱使用者是否為管理員
    public var makeAdmin = false
    /// 建立時寫入偏好設定，讓第一次登入略過設置嚮導
    public var skipSetupAssistant = true
    /// 建立新使用者時要額外套用的偏好設定：項目 id → 值。有出現在這裡就代表啟用，項目清單見 Tweak.catalog
    public var tweaks: [String: String] = [:]

    // 注意：不記錄建立過哪些使用者。舊版設定檔裡的 sandboxes 欄位讀取時會被忽略，下次儲存就消失。

    /// 新沙箱的家目錄放在哪個資料夾底下，家目錄為 <此資料夾>/<帳號>；nil 表示預設 /Users
    public var homeParentDir: String?

    /// 下次儲存範本時，範本資料夾放在哪個目錄底下；nil 表示預設（家目錄）
    public var templateBaseDir: String?

    /// 已儲存的範本，以及建立沙箱時預設套用哪一份（nil 為乾淨環境）
    public var templates: [TemplateRecord] = []
    public var selectedTemplateID: String?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case password, forwardPort, sourcePort, namePrefix, makeAdmin, skipSetupAssistant, tweaks
        case homeParentDir, templateBaseDir, templates, selectedTemplateID
    }

    /// 舊版（只有一份範本）的欄位，只用來讀取並轉成新結構
    private enum LegacyKeys: String, CodingKey {
        case templatePath, templateSavedAt, templateSourceUser, templateSourceGUID, templateSizeBytes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SandboxSettings()
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? d.password
        forwardPort = try c.decodeIfPresent(Int.self, forKey: .forwardPort) ?? d.forwardPort
        sourcePort = try c.decodeIfPresent(Int.self, forKey: .sourcePort) ?? d.sourcePort
        namePrefix = try c.decodeIfPresent(String.self, forKey: .namePrefix) ?? d.namePrefix
        makeAdmin = try c.decodeIfPresent(Bool.self, forKey: .makeAdmin) ?? d.makeAdmin
        skipSetupAssistant = try c.decodeIfPresent(Bool.self, forKey: .skipSetupAssistant) ?? d.skipSetupAssistant
        tweaks = try c.decodeIfPresent([String: String].self, forKey: .tweaks) ?? [:]
        homeParentDir = try c.decodeIfPresent(String.self, forKey: .homeParentDir)
        templateBaseDir = try c.decodeIfPresent(String.self, forKey: .templateBaseDir)
        templates = try c.decodeIfPresent([TemplateRecord].self, forKey: .templates) ?? []
        selectedTemplateID = try c.decodeIfPresent(String.self, forKey: .selectedTemplateID)

        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        if templates.isEmpty, let saved = try legacy.decodeIfPresent(Date.self, forKey: .templateSavedAt) {
            let source = try legacy.decodeIfPresent(String.self, forKey: .templateSourceUser) ?? "?"
            let path = try legacy.decodeIfPresent(String.self, forKey: .templatePath) ?? "/Users/Shared/SandboxMac/template"
            templates = [TemplateRecord(
                id: "legacy", name: "範本（來自 \(source)）", path: path, savedAt: saved, sourceUser: source,
                sourceGUID: try legacy.decodeIfPresent(String.self, forKey: .templateSourceGUID),
                sizeBytes: try legacy.decodeIfPresent(Int64.self, forKey: .templateSizeBytes))]
            selectedTemplateID = "legacy"
        }
    }

    public var selectedTemplate: TemplateRecord? {
        templates.first { $0.id == selectedTemplateID }
    }

    public var effectiveHomeParentDir: String {
        let custom = homeParentDir?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? "/Users" : custom
    }

    /// 預設的範本目錄：~/Library/Application Support/UserForge
    public static var defaultTemplateBaseDir: String { SettingsStore.directory.path }

    public var effectiveTemplateBaseDir: String {
        let custom = templateBaseDir?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? Self.defaultTemplateBaseDir : custom
    }
}

public enum SettingsStore {
    private static let directoryName = "UserForge"
    /// 專案改名前的資料夾名稱，首次啟動時會自動搬遷成新名稱
    private static let legacyDirectoryName = "SandboxMac"

    private static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private static var usesCustomDirectory: Bool {
        ProcessInfo.processInfo.environment["SANDBOX_CONFIG_DIR"]?.hasPrefix("/") == true
    }

    /// 設定與預設範本所在的資料夾：~/Library/Application Support/UserForge。
    /// 環境變數 SANDBOX_CONFIG_DIR 可改成別處（測試用，避免動到真實資料）。
    public static var directory: URL {
        if let custom = ProcessInfo.processInfo.environment["SANDBOX_CONFIG_DIR"], custom.hasPrefix("/") {
            return URL(fileURLWithPath: custom)
        }
        return supportDirectory.appendingPathComponent(directoryName)
    }

    public static var url: URL { directory.appendingPathComponent("settings.json") }

    private static var legacyDirectory: URL { supportDirectory.appendingPathComponent(legacyDirectoryName) }

    /// 舊資料夾存在而新資料夾還不存在時，直接把整個資料夾改名（範本資料夾是 root 擁有也沒關係，
    /// 改名只動上一層的目錄項目）。
    private static func migrateLegacyDirectoryIfNeeded() {
        guard !usesCustomDirectory else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyDirectory.path), !fm.fileExists(atPath: directory.path) else { return }
        try? fm.moveItem(at: legacyDirectory, to: directory)
    }

    public static func load() -> SandboxSettings {
        migrateLegacyDirectoryIfNeeded()
        guard let data = try? Data(contentsOf: url) else { return SandboxSettings() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var settings = try? decoder.decode(SandboxSettings.self, from: data) else { return SandboxSettings() }

        // 資料夾搬遷後，記錄在設定檔裡的範本路徑也要跟著改
        if !usesCustomDirectory {
            let oldPrefix = legacyDirectory.path + "/"
            let newPrefix = directory.path + "/"
            var changed = false
            for index in settings.templates.indices where settings.templates[index].path.hasPrefix(oldPrefix) {
                settings.templates[index].path = newPrefix + settings.templates[index].path.dropFirst(oldPrefix.count)
                changed = true
            }
            if changed { save(settings) }
        }
        return settings
    }

    public static func save(_ settings: SandboxSettings) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
