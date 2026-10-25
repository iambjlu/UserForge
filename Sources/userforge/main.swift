import Foundation
import UserForgeCore

func usage() -> Never {
    print("""
    用法: userforge <指令>

      doctor                         檢查完整磁碟取用權限與鑰匙圈密碼
      users                          列出本機所有一般使用者
      clone <來源帳號> [新帳號] [--full-name 姓名]
                                     把任何現有使用者複製成新使用者
      restore <範本名稱> <帳號>      把範本還原到現有使用者（覆蓋同名檔案，需先登出）
      status                         顯示使用者、範本與設定
      create [帳號] [--full-name 姓名] [--clean | --template 名稱]
                                     建立沙箱使用者，可建立多個
                                     不指定帳號就用 前綴+日期+字母，姓名預設同帳號
                                     預設套用「預設範本」，--clean 為乾淨環境
      save <帳號> [--name 範本名稱] [--delete-user]
                                     把任何使用者備份成範本；加 --delete-user 會在備份後刪除該使用者
                                     同名範本會被覆蓋，不同名稱可以存很多份
      delete <帳號>                  刪除使用者與它的家目錄（不能刪目前使用者與最後一個管理員）
      tweaks                         列出建立時可套用的偏好設定與目前的選擇
      tweak <id> <值>|off            啟用某個偏好設定並指定值，off 為停用
      templates                      列出所有範本
      template-use <名稱>|--clean    設定建立沙箱時預設套用的範本
      template-rename <名稱> <新名稱>
      template-size [名稱]           重新計算範本佔用的空間
      template-export <名稱> <zip 路徑>
                                     把範本壓縮匯出成 zip（內含完整家目錄，請妥善保管）
      template-import <zip 路徑>     從 zip 匯入範本（只匯入你信任的檔案）
      template-delete <名稱>|--all   刪除範本
      config [key value]             顯示或修改設定
                                     key: password, port, source, prefix, admin, skip-setup,
                                          template-dir, home-dir
                                     template-dir / home-dir 設為 default 可還原預設
      forward                        前景執行埠轉發，Ctrl-C 結束

    管理員密碼由環境變數 SANDBOX_ADMIN_PASSWORD 提供，其次是鑰匙圈，最後在終端機詢問。
    環境變數 SANDBOX_CONFIG_DIR 可指定另一個設定資料夾（測試用）。
    """)
    exit(2)
}

func adminPassword() -> String? {
    if let p = ProcessInfo.processInfo.environment["SANDBOX_ADMIN_PASSWORD"] { return p }
    if let p = AdminCredential.load() { return p }
    if isatty(0) == 1, let p = getpass("管理員密碼: ") { return String(cString: p) }
    return nil
}

func manager() -> SandboxManager {
    SandboxManager(adminPassword: adminPassword()) { print($0); fflush(stdout) }
}

func printTemplates(_ s: SandboxSettings) {
    if s.templates.isEmpty { print("範本: 無"); return }
    print("範本:")
    for t in s.templates {
        let size = t.sizeBytes.map { SandboxManager.formatBytes($0) } ?? "未知"
        print("  \(t.id == s.selectedTemplateID ? "*" : " ") \(t.name)  [\(t.id)]  來自 \(t.sourceUser)  \(size)  \(t.savedAt.formatted(date: .abbreviated, time: .shortened))")
        print("      \(t.path)")
    }
    print("  (* 為建立沙箱時的預設範本)")
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

do {
    switch command {
    case "doctor":
        print("完整磁碟取用權限: \(FullDiskAccess.isGranted ? "已授予" : "未授予。" + FullDiskAccess.hint)")
        print("鑰匙圈中的管理員密碼: \(AdminCredential.load() != nil ? "已儲存" : "未儲存")")
    case "users":
        let users = manager().localUsers()
        if users.isEmpty { print("找不到使用者") }
        for u in users {
            let tags = [u.isCurrent ? "目前使用者" : nil, u.loggedIn ? "登入中" : nil, u.isAdmin ? "管理員" : nil]
                .compactMap { $0 }.joined(separator: "、")
            print("  \(u.name)  uid=\(u.uid)  \(u.fullName)  \(u.home)\(tags.isEmpty ? "" : "  [\(tags)]")")
        }
    case "clone":
        // userforge clone <來源帳號> [新帳號] [--full-name 姓名]
        guard args.count >= 2, !args[1].hasPrefix("--") else { usage() }
        var newName: String?
        var fullName: String?
        var rest = args.dropFirst(2)
        while let arg = rest.popFirst() {
            if arg == "--full-name" { fullName = rest.popFirst() } else if !arg.hasPrefix("--") { newName = arg } else { usage() }
        }
        try manager().cloneUser(from: args[1], name: newName, fullName: fullName)
    case "restore":
        guard args.count >= 3 else { usage() }
        try manager().restoreTemplate(args[1], to: args[2])
    case "tweaks":
        let chosen = SettingsStore.load().tweaks
        for category in Tweak.categories {
            print(category)
            for t in Tweak.catalog where t.category == category {
                var choices = ""
                switch t.kind {
                case .bool: choices = "true|false"
                case .choice(let options): choices = options.map { $0.value.isEmpty ? "(預設)" : $0.value }.joined(separator: "|")
                case .int(let range, _): choices = "\(range.lowerBound)-\(range.upperBound)"
                }
                print("  \(chosen[t.id] != nil ? "[x]" : "[ ]") \(t.id)  \(t.title)  值: \(choices)\(chosen[t.id].map { "  目前: \($0.isEmpty ? "(預設)" : $0)" } ?? "")")
            }
        }
    case "tweak":
        guard args.count >= 3, let t = Tweak.find(args[1]) else { usage() }
        var s = SettingsStore.load()
        if args[2] == "off" {
            s.tweaks[t.id] = nil
        } else {
            guard let value = t.normalizedValue(args[2] == "default" ? "" : args[2]) else { throw SandboxError("值不合法：\(args[2])") }
            s.tweaks[t.id] = value
        }
        SettingsStore.save(s)
    case "status":
        let s = SettingsStore.load()
        for u in manager().localUsers() { print("  \(u.name)  \(u.fullName)  \(u.home)") }
        printTemplates(s)
        print("下次儲存範本的目錄: \(s.effectiveTemplateBaseDir)\(s.templateBaseDir == nil ? "（預設）" : "")")
        print("密碼: \(s.password)  轉發: \(s.forwardPort) ← \(s.sourcePort)  前綴: \(s.namePrefix)  管理員: \(s.makeAdmin)  略過設置嚮導: \(s.skipSetupAssistant)")
    case "create":
        // userforge create [帳號] [--full-name 姓名] [--clean | --template 名稱]
        var name: String?
        var fullName: String?
        var selection = TemplateSelection.selected
        var rest = args.dropFirst()
        while let arg = rest.popFirst() {
            switch arg {
            case "--full-name": fullName = rest.popFirst()
            case "--clean": selection = .clean
            case "--template":
                guard let key = rest.popFirst() else { usage() }
                selection = .template(key)
            default:
                if arg.hasPrefix("--") { usage() }
                name = arg
            }
        }
        try manager().create(name: name, fullName: fullName, template: selection)
    case "save":
        guard args.count >= 2, !args[1].hasPrefix("--") else { usage() }
        var templateName: String?
        if let i = args.firstIndex(of: "--name"), i + 1 < args.count { templateName = args[i + 1] }
        try manager().saveTemplate(from: args[1], as: templateName, deleteUser: args.contains("--delete-user"))
    case "delete":
        guard args.count >= 2 else { usage() }
        try manager().delete(name: args[1])
    case "templates":
        printTemplates(SettingsStore.load())
    case "template-use":
        guard args.count >= 2 else { usage() }
        var s = SettingsStore.load()
        if args[1] == "--clean" {
            s.selectedTemplateID = nil
        } else {
            guard let t = s.templates.first(where: { $0.id == args[1] || $0.name == args[1] }) else {
                throw SandboxError("找不到範本「\(args[1])」")
            }
            s.selectedTemplateID = t.id
        }
        SettingsStore.save(s)
        printTemplates(s)
    case "template-rename":
        guard args.count >= 3 else { usage() }
        try manager().renameTemplate(args[1], to: args[2])
    case "template-size":
        try manager().refreshTemplateSize(args.count >= 2 ? args[1] : nil)
    case "template-export":
        guard args.count >= 3 else { usage() }
        try manager().exportTemplate(args[1], to: args[2])
    case "template-import":
        guard args.count >= 2 else { usage() }
        try manager().importTemplate(from: args[1])
    case "template-delete":
        guard args.count >= 2 else { usage() }
        if args[1] == "--all" { try manager().deleteAllTemplates() } else { try manager().deleteTemplate(args[1]) }
    case "config":
        var s = SettingsStore.load()
        if args.count == 3 {
            let value = args[2]
            switch args[1] {
            case "password": s.password = value
            case "port": s.forwardPort = Int(value) ?? s.forwardPort
            case "source": s.sourcePort = Int(value) ?? s.sourcePort
            case "prefix": s.namePrefix = value
            case "admin": s.makeAdmin = ["1", "true", "yes"].contains(value)
            case "skip-setup": s.skipSetupAssistant = ["1", "true", "yes"].contains(value)
            case "template-dir": s.templateBaseDir = value == "default" ? nil : value
            case "home-dir": s.homeParentDir = value == "default" ? nil : value
            default: usage()
            }
            SettingsStore.save(s)
        }
        print("password=\(s.password) port=\(s.forwardPort) source=\(s.sourcePort) prefix=\(s.namePrefix) admin=\(s.makeAdmin) skip-setup=\(s.skipSetupAssistant) template-dir=\(s.effectiveTemplateBaseDir) home-dir=\(s.effectiveHomeParentDir)")
    case "forward":
        let s = SettingsStore.load()
        let forwarder = PortForwarder()
        forwarder.onEvent = { print($0); fflush(stdout) }
        try forwarder.start(listenPort: s.forwardPort, targetPort: s.sourcePort)
        dispatchMain()
    default:
        usage()
    }
} catch {
    FileHandle.standardError.write(Data("錯誤: \(error.localizedDescription)\n".utf8))
    exit(1)
}
