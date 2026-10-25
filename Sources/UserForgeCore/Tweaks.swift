import Foundation

/// 建立新使用者時可以一併寫入的偏好設定。
/// 全部寫進新使用者自己的 ~/Library/Preferences，不會動到系統層級（/Library）的設定，
/// 所以不會影響你自己的帳號或其他使用者。
public struct Tweak: Identifiable {
    public enum Kind {
        /// 開 / 關
        case bool
        /// 固定幾個選項；值為空字串代表「刪除這個設定」（還原成系統預設）
        case choice([(label: String, value: String)])
        /// 整數
        case int(range: ClosedRange<Int>, default: Int)
    }

    public let id: String
    public let title: String
    public let category: String
    /// 偏好設定檔名（不含 .plist），例如 com.apple.dock；全域設定是 .GlobalPreferences
    public let file: String
    public let key: String
    public let kind: Kind
    /// 勾選時的預設值
    public let defaultValue: String

    /// 檢查值是否合法，避免把任意字串寫進偏好設定
    public func normalizedValue(_ value: String) -> String? {
        switch kind {
        case .bool:
            return ["true", "false"].contains(value) ? value : nil
        case .choice(let options):
            return options.contains { $0.value == value } ? value : nil
        case .int(let range, _):
            guard let n = Int(value), range.contains(n) else { return nil }
            return String(n)
        }
    }

    private static let global = ".GlobalPreferences"
    private static let dock = "com.apple.dock"
    private static let finder = "com.apple.finder"
    private static let access = "com.apple.universalaccess"

    private static func boolTweak(_ id: String, _ title: String, _ category: String, _ file: String, _ key: String,
                                  default value: Bool) -> Tweak {
        Tweak(id: id, title: title, category: category, file: file, key: key, kind: .bool, defaultValue: String(value))
    }

    private static func choiceTweak(_ id: String, _ title: String, _ category: String, _ file: String, _ key: String,
                                    _ options: [(label: String, value: String)]) -> Tweak {
        Tweak(id: id, title: title, category: category, file: file, key: key, kind: .choice(options),
              defaultValue: options[0].value)
    }

    public static let catalog: [Tweak] = [
        // 外觀與輔助使用
        choiceTweak("dark-mode", "外觀", "外觀與輔助使用", global, "AppleInterfaceStyle",
                    [("深色", "Dark"), ("淺色", "")]),
        boolTweak("reduce-transparency", "降低透明度", "外觀與輔助使用", access, "reduceTransparency", default: true),
        boolTweak("reduce-motion", "減少動態效果", "外觀與輔助使用", access, "reduceMotion", default: true),
        boolTweak("window-animations", "視窗開關動畫", "外觀與輔助使用", global, "NSAutomaticWindowAnimationsEnabled",
                  default: false),

        // Dock
        boolTweak("dock-launchanim", "Dock 開啟 App 的彈跳動畫", "Dock", dock, "launchanim", default: false),
        choiceTweak("dock-mineffect", "視窗最小化效果", "Dock", dock, "mineffect",
                    [("縮放", "scale"), ("神奇", "genie"), ("吸入", "suck")]),
        boolTweak("dock-autohide", "自動隱藏 Dock", "Dock", dock, "autohide", default: true),
        Tweak(id: "dock-tilesize", title: "Dock 圖示大小", category: "Dock", file: dock, key: "tilesize",
              kind: .int(range: 16...128, default: 36), defaultValue: "36"),
        choiceTweak("dock-orientation", "Dock 位置", "Dock", dock, "orientation",
                    [("左側", "left"), ("底部", "bottom"), ("右側", "right")]),
        boolTweak("dock-show-recents", "Dock 顯示最近使用的 App", "Dock", dock, "show-recents", default: false),

        // Finder
        boolTweak("finder-extensions", "顯示所有副檔名", "Finder", global, "AppleShowAllExtensions", default: true),
        boolTweak("finder-pathbar", "顯示路徑列", "Finder", finder, "ShowPathbar", default: true),
        boolTweak("finder-statusbar", "顯示狀態列", "Finder", finder, "ShowStatusBar", default: true),
        boolTweak("finder-hidden", "顯示隱藏檔案", "Finder", finder, "AppleShowAllFiles", default: true),
        choiceTweak("finder-view", "Finder 預設檢視", "Finder", finder, "FXPreferredViewStyle",
                    [("列表", "Nlsv"), ("圖示", "icnv"), ("欄", "clmv"), ("圖庫", "glyv")]),

        // 其他
        boolTweak("icloud-save", "新文件預設存到 iCloud", "其他", global, "NSDocumentSaveNewDocumentsToCloud",
                  default: false),
        boolTweak("press-and-hold", "長按字母顯示重音符號選單", "其他", global, "ApplePressAndHoldEnabled", default: false),
        boolTweak("stage-manager", "Stage Manager", "其他", "com.apple.WindowManager", "GloballyEnabled", default: false),
    ]

    public static func find(_ id: String) -> Tweak? { catalog.first { $0.id == id } }

    /// 依分類分組，保持目錄順序
    public static var categories: [String] {
        var seen: [String] = []
        for tweak in catalog where !seen.contains(tweak.category) { seen.append(tweak.category) }
        return seen
    }
}
