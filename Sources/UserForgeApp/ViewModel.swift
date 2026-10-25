import AppKit
import Foundation
import UserForgeCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ViewModel: ObservableObject {
    @Published var settings = SettingsStore.load()
    /// 本機所有一般使用者（不限本程式建立的），每次操作後重新讀取
    @Published var localUsers: [LocalUser] = []
    /// 建立沙箱時的帳號與姓名。沒有手動改過就會跟著預設規則更新。
    @Published var newName = ""
    @Published var newFullName = ""
    private var nameEdited = false
    private var fullNameEdited = false
    /// 從鑰匙圈讀出，用來執行 sudo；沒有的話第一次操作時會跳對話框詢問
    @Published var adminPassword = AdminCredential.load() ?? ""
    @Published var showPasswordSheet = false
    @Published var passwordError: String?
    @Published var verifyingPassword = false
    @Published var hasFullDiskAccess = FullDiskAccess.isGranted
    /// 等使用者輸入密碼後要接著執行的操作
    private var pendingRun: (() -> Void)?
    @Published var log = ""
    @Published var busy = false
    @Published var forwarding = false
    /// 正在做的實際工作（建立、刪除、備份…）；啟動時的重新整理這類安靜的操作不算
    @Published var currentTask: String?

    /// 轉發中或有工作在進行，這時才需要選單列圖示與退出詢問
    var isActive: Bool { forwarding || currentTask != nil }

    /// AppDelegate 與選單列也要用同一個實例
    static let shared = ViewModel()

    private let forwarder = PortForwarder()

    init() {
        forwarder.onEvent = { [weak self] line in
            Task { @MainActor in self?.append(line) }
        }
    }

    var usingDefaultTemplateDir: Bool { settings.templateBaseDir == nil }

    // MARK: - 建立時的偏好設定

    func tweakEnabled(_ tweak: Tweak) -> Binding<Bool> {
        Binding(
            get: { self.settings.tweaks[tweak.id] != nil },
            set: { on in self.settings.tweaks[tweak.id] = on ? tweak.defaultValue : nil })
    }

    func tweakValue(_ tweak: Tweak) -> Binding<String> {
        Binding(
            get: { self.settings.tweaks[tweak.id] ?? tweak.defaultValue },
            set: { self.settings.tweaks[tweak.id] = $0 })
    }

    // MARK: - 管理員密碼

    var hasAdminPassword: Bool { !adminPassword.isEmpty }

    /// 驗證後存入鑰匙圈，成功就接著執行剛才被擋下的操作
    func submitAdminPassword(_ password: String) {
        guard !verifyingPassword else { return }
        verifyingPassword = true
        passwordError = nil
        Task.detached { [weak self] in
            let valid = AdminCredential.verify(password)
            var saveError: String?
            if valid {
                do { try AdminCredential.save(password) } catch { saveError = error.localizedDescription }
            }
            await self?.passwordChecked(password, valid: valid, saveError: saveError)
        }
    }

    private func passwordChecked(_ password: String, valid: Bool, saveError: String?) {
        verifyingPassword = false
        guard valid else {
            passwordError = "密碼不正確，或這個帳號不是管理員"
            return
        }
        adminPassword = password
        if let saveError { append("⚠︎ \(saveError)，這次仍可使用，但下次要重新輸入") }
        showPasswordSheet = false
        let next = pendingRun
        pendingRun = nil
        next?()
    }

    func cancelPasswordPrompt() {
        showPasswordSheet = false
        pendingRun = nil
        passwordError = nil
    }

    /// 忘記已儲存的密碼；下次操作會重新詢問
    func forgetAdminPassword() {
        AdminCredential.delete()
        adminPassword = ""
    }

    // MARK: - 完整磁碟取用權限

    func recheckPermissions() {
        hasFullDiskAccess = FullDiskAccess.isGranted
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: FullDiskAccess.settingsURL) { NSWorkspace.shared.open(url) }
    }

    /// 授權後要重新啟動 App 才會生效
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: - 帳號與姓名輸入框

    var nameBinding: Binding<String> {
        Binding(
            get: { self.newName },
            set: { value in
                self.newName = value
                // 清空代表回到預設規則
                self.nameEdited = !value.isEmpty
                if value.isEmpty { self.refreshSuggestion() }
                if !self.fullNameEdited { self.newFullName = self.newName }
            })
    }

    var fullNameBinding: Binding<String> {
        Binding(
            get: { self.newFullName },
            set: { value in
                self.newFullName = value
                self.fullNameEdited = !value.isEmpty
                if value.isEmpty { self.newFullName = self.newName }
            })
    }

    /// 重新計算預設帳號；沒手動改過的欄位才會被更新
    func refreshSuggestion() {
        // 操作進行中磁碟上的資料較新，不能用畫面上的舊資料覆蓋
        if !busy { persist() }
        Task.detached { [weak self] in
            let suggestion = SandboxManager(adminPassword: nil, log: { _ in }).suggestedName()
            await self?.applySuggestion(suggestion)
        }
    }

    private func applySuggestion(_ suggestion: String) {
        if !nameEdited { newName = suggestion }
        if !fullNameEdited { newFullName = newName }
    }

    private func resetNameFields() {
        nameEdited = false
        fullNameEdited = false
        refreshSuggestion()
    }

    func append(_ line: String) {
        log += line + "\n"
        // 記錄只留在記憶體，超過上限就丟掉最舊的部分
        if log.count > 100_000 { log = String(log.suffix(50_000)) }
    }

    func persist() {
        SettingsStore.save(settings)
    }

    // MARK: - 範本目錄

    func chooseTemplateDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "選擇"
        panel.message = "範本會存在這個資料夾底下，每份範本一個 \(SandboxManager.templateFolderPrefix)-編號 子資料夾"
        if panel.runModal() == .OK, let url = panel.url {
            settings.templateBaseDir = url.path
            persist()
        }
    }

    var usingDefaultHomeParent: Bool { settings.homeParentDir == nil }

    func chooseHomeParent() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "選擇"
        panel.message = "新使用者的家目錄會建立在這個資料夾底下，名稱為帳號"
        if panel.runModal() == .OK, let url = panel.url {
            settings.homeParentDir = url.path
            persist()
        }
    }

    func useDefaultHomeParent() {
        settings.homeParentDir = nil
        persist()
    }

    func useDefaultTemplateDir() {
        settings.templateBaseDir = nil
        persist()
    }

    func revealTemplate(_ template: TemplateRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: template.path)])
    }

    // MARK: - 埠轉發

    func toggleForward() {
        if forwarding {
            forwarder.stop()
            forwarding = false
            return
        }
        persist()
        do {
            try forwarder.start(listenPort: settings.forwardPort, targetPort: settings.sourcePort)
            forwarding = true
        } catch {
            append("✗ \(error.localizedDescription)")
        }
    }

    func openScreenSharing() {
        if let url = URL(string: "vnc://localhost:\(settings.forwardPort)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 沙箱操作

    func createSandbox() {
        let name = newName, fullName = newFullName
        run("建立使用者", resetsName: true) { try $0.create(name: name, fullName: fullName) }
    }
    func saveTemplate(from user: String, as templateName: String, deleteUser: Bool) {
        run("以 \(user) 儲存範本") { try $0.saveTemplate(from: user, as: templateName, deleteUser: deleteUser) }
    }
    func cloneUser(from source: String, name: String, fullName: String) {
        run("複製 \(source) 為新使用者", resetsName: true) {
            try $0.cloneUser(from: source, name: name, fullName: fullName)
        }
    }
    func restoreTemplate(_ template: TemplateRecord, to user: String) {
        run("還原範本「\(template.name)」到 \(user)") { try $0.restoreTemplate(template.id, to: user) }
    }
    func deleteUser(_ name: String) { run("刪除使用者 \(name)") { try $0.delete(name: name) } }

    func deleteTemplate(_ template: TemplateRecord) {
        run("刪除範本「\(template.name)」") { try $0.deleteTemplate(template.id) }
    }
    func renameTemplate(_ template: TemplateRecord, to newName: String) {
        run("重新命名範本", needsAdmin: false) { try $0.renameTemplate(template.id, to: newName) }
    }
    func exportTemplate(_ template: TemplateRecord) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(template.name).sandboxtemplate.zip"
        panel.message = "範本會壓縮成一個 zip 檔。內含完整家目錄，請妥善保管"
        panel.prompt = "匯出"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run("匯出範本「\(template.name)」") { try $0.exportTemplate(template.id, to: url.path) }
    }

    func importTemplate() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "選擇範本 zip 檔。只匯入你信任的檔案，範本內容會原樣還原到新使用者"
        panel.prompt = "匯入"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run("匯入範本") { _ = try $0.importTemplate(from: url.path) }
    }

    func recalculateTemplateSize(_ template: TemplateRecord) {
        run("計算範本大小") { try $0.refreshTemplateSize(template.id) }
    }
    func refresh() { run("重新整理", needsAdmin: false) { _ in } }

    private func run(_ title: String, resetsName: Bool = false, needsAdmin: Bool = true,
                     _ work: @escaping @Sendable (SandboxManager) throws -> Void) {
        guard !busy else { return }
        if needsAdmin, adminPassword.isEmpty {
            pendingRun = { [weak self] in self?.run(title, resetsName: resetsName, work) }
            passwordError = nil
            showPasswordSheet = true
            return
        }
        busy = true
        if needsAdmin { currentTask = title }
        persist()
        append("▶ \(title)")
        let password = adminPassword
        Task.detached { [weak self] in
            let manager = SandboxManager(adminPassword: password) { line in
                Task { @MainActor in self?.append(line) }
            }
            var succeeded = true
            do {
                try work(manager)
                await self?.append("✓ 完成")
            } catch {
                succeeded = false
                await self?.append("✗ \(error.localizedDescription)")
                // 已儲存的密碼失效（例如改過管理員密碼），清掉讓下次重新詢問
                if error.localizedDescription == "管理員密碼錯誤" { await self?.forgetAdminPassword() }
            }
            let users = manager.localUsers()
            await self?.finishOperation(resetName: resetsName && succeeded, users: users)
        }
    }

    private func finishOperation(resetName: Bool, users: [LocalUser]) {
        settings = SettingsStore.load()
        localUsers = users
        busy = false
        currentTask = nil
        // 成功建立後，下一個沙箱回到預設規則；其他操作（例如刪除）可能釋出名稱，也重新計算
        if resetName { resetNameFields() } else { refreshSuggestion() }
    }
}
