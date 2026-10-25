import SwiftUI
import UserForgeCore

/// 需要輸入範本名稱的兩種情況
private enum NameRequest: Identifiable {
    case save(user: String, deleteUser: Bool)
    case rename(TemplateRecord)

    var id: String {
        switch self {
        case .save(let user, let deleteUser): return "save-\(user)-\(deleteUser)"
        case .rename(let template): return "rename-\(template.id)"
        }
    }
}

private struct CloneRequest: Identifiable {
    let source: String
    var id: String { source }
}

private struct RestoreRequest: Identifiable {
    let template: TemplateRecord
    let user: String
    var id: String { template.id + "-" + user }
}

struct ContentView: View {
    @EnvironmentObject var model: ViewModel
    @State private var pendingDelete: String?
    @State private var templateToDelete: TemplateRecord?
    @State private var passwordInput = ""
    @State private var nameRequest: NameRequest?
    @State private var nameInput = ""
    @State private var cloneRequest: CloneRequest?
    @State private var cloneName = ""
    @State private var cloneFullName = ""
    @State private var restoreRequest: RestoreRequest?
    @State private var showOptions = false

    var body: some View {
        Form {
            if !model.hasFullDiskAccess { permissionSection }
            settingsSection
            forwardSection
            createSection
            usersSection
            templateSection
            logSection
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "刪除使用者 \(pendingDelete ?? "")？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("刪除使用者與家目錄", role: .destructive) {
                if let name = pendingDelete { model.deleteUser(name) }
                pendingDelete = nil
            }
        } message: {
            Text(deleteWarning(for: pendingDelete))
        }
        .confirmationDialog(
            "刪除範本「\(templateToDelete?.name ?? "")」？",
            isPresented: Binding(get: { templateToDelete != nil }, set: { if !$0 { templateToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("刪除", role: .destructive) {
                if let template = templateToDelete { model.deleteTemplate(template) }
                templateToDelete = nil
            }
        }
        .confirmationDialog(
            "把範本「\(restoreRequest?.template.name ?? "")」還原到 \(restoreRequest?.user ?? "")？",
            isPresented: Binding(get: { restoreRequest != nil }, set: { if !$0 { restoreRequest = nil } }),
            titleVisibility: .visible
        ) {
            Button("還原並覆蓋", role: .destructive) {
                if let request = restoreRequest { model.restoreTemplate(request.template, to: request.user) }
                restoreRequest = nil
            }
        } message: {
            Text("會覆蓋這個使用者家目錄中同名的檔案，無法復原；多出來的檔案不會被刪除。")
        }
        .onAppear {
            model.refresh()
            model.refreshSuggestion()
            model.recheckPermissions()
        }
        // 使用者從系統設定回來時重新檢查
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.recheckPermissions()
        }
        .sheet(isPresented: $model.showPasswordSheet) { passwordSheet }
        .sheet(item: $nameRequest) { request in nameSheet(request) }
        .sheet(item: $cloneRequest) { request in cloneSheet(request) }
    }

    private func deleteWarning(for name: String?) -> String {
        var text = "會刪除這個使用者與它的家目錄，無法復原。"
        if let user = model.localUsers.first(where: { $0.name == name }) {
            if user.loggedIn { text += "\(user.name) 目前登入中，會被強制登出。" }
            if user.isAdmin { text += "這是管理員帳號。" }
        }
        return text
    }

    // MARK: - 權限

    private var permissionSection: some View {
        Section {
            Label {
                Text("尚未授予「完整磁碟取用權限」。備份或還原其他使用者的家目錄時，受保護的資料夾（Safari、郵件、桌面與文件等）會失敗。")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            }
            Text("請在系統設定的清單中開啟 UserForge，授予後按「重新啟動 App」才會生效。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("開啟系統設定") { model.openFullDiskAccessSettings() }
                Button("重新檢查") { model.recheckPermissions() }
                Button("重新啟動 App") { model.relaunch() }
            }
        }
    }

    private var passwordSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("需要管理員密碼").font(.headline)
            Text("建立與刪除使用者需要管理員權限。輸入一次後會存進登入鑰匙圈，之後不會再詢問。")
                .font(.callout)
                .foregroundStyle(.secondary)
            SecureField("「\(NSUserName())」的密碼", text: $passwordInput)
                .onSubmit { submitPassword() }
            if let error = model.passwordError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                if model.verifyingPassword { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") {
                    passwordInput = ""
                    model.cancelPasswordPrompt()
                }
                .keyboardShortcut(.cancelAction)
                Button("儲存並繼續") { submitPassword() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(passwordInput.isEmpty || model.verifyingPassword)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func submitPassword() {
        guard !passwordInput.isEmpty else { return }
        model.submitAdminPassword(passwordInput)
        passwordInput = ""
    }

    // MARK: - 範本命名

    private func nameSheet(_ request: NameRequest) -> some View {
        let isSave: Bool
        let title: String
        var deletesUser = false
        var sourceUser = ""
        switch request {
        case .save(let user, let deleteUser):
            isSave = true
            deletesUser = deleteUser
            sourceUser = user
            title = "備份 \(user) 為範本"
        case .rename(let template):
            isSave = false
            title = "重新命名「\(template.name)」"
        }
        let trimmed = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let overwrites = isSave && model.settings.templates.contains { $0.name == trimmed }

        return VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("範本名稱", text: $nameInput)
                .onSubmit { confirmName(request) }
            if overwrites {
                Text("已有同名範本，儲存後會覆蓋它。想保留舊的請改個名稱。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if isSave {
                Text("同一個帳號可以存很多份範本，名稱不同就不會覆蓋。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if deletesUser {
                Text("備份完成後會刪除使用者 \(sourceUser) 與它的家目錄，無法復原。")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { nameRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button(isSave ? (deletesUser ? "備份並刪除" : "備份") : "重新命名") { confirmName(request) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func confirmName(_ request: NameRequest) {
        let name = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch request {
        case .save(let user, let deleteUser): model.saveTemplate(from: user, as: name, deleteUser: deleteUser)
        case .rename(let template): model.renameTemplate(template, to: name)
        }
        nameRequest = nil
    }

    private func askSave(user: String, deleteUser: Bool) {
        nameInput = SandboxManager.suggestedTemplateName(sourceUser: user)
        nameRequest = .save(user: user, deleteUser: deleteUser)
    }

    // MARK: - 複製使用者

    private func startClone(_ source: String) {
        cloneName = model.newName
        cloneFullName = model.newName
        cloneRequest = CloneRequest(source: source)
    }

    private func cloneSheet(_ request: CloneRequest) -> some View {
        let source = model.localUsers.first { $0.name == request.source }
        return VStack(alignment: .leading, spacing: 12) {
            Text("複製 \(request.source) 為新使用者").font(.headline)
            TextField("新使用者帳號", text: $cloneName)
            TextField("新使用者姓名", text: $cloneFullName)
            Text("密碼、管理員身分、家目錄位置與「選項」裡勾選的設定，使用主視窗「建立新使用者」的設定。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if source?.loggedIn == true {
                Text("\(request.source) 目前登入中，複製期間檔案可能仍在變動，建議先登出。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("若新使用者的密碼與來源不同，複製過來的登入鑰匙圈需要用來源的密碼解鎖。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { cloneRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button("複製") {
                    model.cloneUser(from: request.source, name: cloneName, fullName: cloneFullName)
                    cloneRequest = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(cloneName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: - 設定

    private var settingsSection: some View {
        Section("設定") {
            LabeledContent("管理員密碼") {
                HStack {
                    Text(model.hasAdminPassword ? "已儲存在鑰匙圈" : "尚未設定，第一次操作時會詢問")
                        .foregroundStyle(.secondary)
                    if model.hasAdminPassword {
                        Button("忘記") { model.forgetAdminPassword() }
                    }
                }
            }
        }
        .disabled(model.busy)
        .onChange(of: model.settings) { _ in model.persist() }
    }

    // MARK: - 埠轉發

    private var forwardSection: some View {
        Section("埠轉發") {
            HStack(spacing: 8) {
                Text("本機轉發埠").fixedSize()
                TextField("", value: $model.settings.forwardPort, format: .number.grouping(.never))
                    .labelsHidden()
                    .frame(width: 90)
                Text("←").foregroundStyle(.secondary)
                Text("來源埠").fixedSize()
                TextField("", value: $model.settings.sourcePort, format: .number.grouping(.never))
                    .labelsHidden()
                    .frame(width: 90)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Circle()
                    .fill(model.forwarding ? Color.green : Color.secondary)
                    .frame(width: 10, height: 10)
                Text(model.forwarding ? "轉發中" : "未啟動").foregroundStyle(.secondary)
                Spacer()
                Button(model.forwarding ? "停止轉發" : "開始轉發") { model.toggleForward() }
            }
            // 用 String 而不是字串插值，避免埠號被格式化成 5,910
            Button("用螢幕共享開啟 " + "vnc://localhost:" + String(model.settings.forwardPort)) {
                model.openScreenSharing()
            }
            .disabled(!model.forwarding)
        }
    }

    // MARK: - 建立新使用者

    private var createSection: some View {
        Section("建立新使用者") {
            TextField("新使用者帳號（留空使用預設）", text: model.nameBinding)
            TextField("新使用者姓名（預設同帳號）", text: model.fullNameBinding)
            SecureField("新使用者密碼", text: $model.settings.password)
            Toggle("使用者為管理員", isOn: $model.settings.makeAdmin)
            Picker("套用範本", selection: $model.settings.selectedTemplateID) {
                Text("不套用範本（乾淨環境）").tag(String?.none)
                ForEach(model.settings.templates) { template in
                    Text(template.name).tag(Optional(template.id))
                }
            }
            HStack {
                Text("家目錄位置")
                Button("預設") { model.useDefaultHomeParent() }
                    .disabled(model.usingDefaultHomeParent)
                Spacer()
                Text("\(model.settings.effectiveHomeParentDir)/\(model.newName)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button("選擇…") { model.chooseHomeParent() }
            }
            HStack {
                Spacer()
                Button("選項…") { showOptions.toggle() }
                    .popover(isPresented: $showOptions, arrowEdge: .bottom) { optionsPopover }
            }
            HStack {
                Spacer()
                Button("建立使用者") { model.createSandbox() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .disabled(model.busy)
    }

    // MARK: - 建立時的偏好設定

    private var optionsPopover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("建立新使用者時一併套用").font(.headline)
                Text("勾選的項目會寫進新使用者自己的偏好設定，不會動到你自己或其他使用者，第一次登入後生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("跳過設置嚮導", isOn: $model.settings.skipSetupAssistant)

                ForEach(Tweak.categories, id: \.self) { category in
                    Text(category).font(.subheadline.bold()).padding(.top, 6)
                    ForEach(Tweak.catalog.filter { $0.category == category }) { tweak in
                        HStack {
                            Toggle(tweak.title, isOn: model.tweakEnabled(tweak))
                            Spacer()
                            tweakValueControl(tweak)
                                .disabled(model.settings.tweaks[tweak.id] == nil)
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("全部取消勾選") { model.settings.tweaks = [:] }
                        .disabled(model.settings.tweaks.isEmpty)
                }
                .padding(.top, 6)
            }
            .padding(16)
        }
        .frame(width: 440, height: 480)
    }

    @ViewBuilder
    private func tweakValueControl(_ tweak: Tweak) -> some View {
        switch tweak.kind {
        case .bool:
            Picker("", selection: model.tweakValue(tweak)) {
                Text("開").tag("true")
                Text("關").tag("false")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 90)
        case .choice(let options):
            Picker("", selection: model.tweakValue(tweak)) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .frame(width: 90)
        case .int(let range, let fallback):
            Stepper(
                value: Binding(
                    get: { Int(model.tweakValue(tweak).wrappedValue) ?? fallback },
                    set: { model.tweakValue(tweak).wrappedValue = String($0) }),
                in: range
            ) {
                Text(model.tweakValue(tweak).wrappedValue).monospacedDigit()
            }
            .frame(width: 90)
        }
    }

    // MARK: - 本機使用者（任何帳號都能備份、複製、還原、刪除）

    private var usersSection: some View {
        Section("使用者") {
            Text("列出本機所有一般使用者，不限於本程式建立的（本程式不記錄建立過哪些使用者）。刪除時不能刪目前使用者與最後一個管理員。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.localUsers.isEmpty {
                Text("讀取中…").foregroundStyle(.secondary)
            }
            ForEach(model.localUsers) { user in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.fullName == user.name ? user.name : "\(user.fullName)（\(user.name)）")
                            .textSelection(.enabled)
                        let tags = [user.isCurrent ? "目前使用者" : nil, user.loggedIn ? "登入中" : nil,
                                    user.isAdmin ? "管理員" : nil].compactMap { $0 }
                        Text(([user.home] + tags).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Menu("操作") {
                        Button("備份為範本…") { askSave(user: user.name, deleteUser: false) }
                        Button("備份為範本並刪除使用者…") { askSave(user: user.name, deleteUser: true) }
                            .disabled(user.isCurrent)
                        Button("複製為新使用者…") { startClone(user.name) }
                        Menu("還原範本到此使用者") {
                            ForEach(model.settings.templates) { template in
                                Button(template.name) {
                                    restoreRequest = RestoreRequest(template: template, user: user.name)
                                }
                            }
                        }
                        .disabled(model.settings.templates.isEmpty || user.loggedIn)
                        Divider()
                        Button("刪除使用者…", role: .destructive) { pendingDelete = user.name }
                            .disabled(user.isCurrent)
                    }
                    .fixedSize()
                }
            }
        }
        .disabled(model.busy)
    }

    // MARK: - 範本

    private var templateSection: some View {
        Section("範本") {
            if model.settings.templates.isEmpty {
                Text("尚未建立。在「使用者」清單中，用該使用者右邊的「操作」備份成範本。")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.settings.templates) { template in
                HStack {
                    Image(systemName: template.id == model.settings.selectedTemplateID ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(template.id == model.settings.selectedTemplateID ? Color.accentColor : .secondary)
                        .help("建立使用者時預設套用")
                        .onTapGesture { model.settings.selectedTemplateID = template.id }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(template.name).textSelection(.enabled)
                        Text("來自 \(template.sourceUser) · \(template.savedAt.formatted(date: .abbreviated, time: .shortened)) · \(template.sizeBytes.map { SandboxManager.formatBytes($0) } ?? "大小未知")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(template.path)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Menu("管理") {
                        Button("設為預設") { model.settings.selectedTemplateID = template.id }
                        Button("重新命名…") {
                            nameInput = template.name
                            nameRequest = .rename(template)
                        }
                        Button("重新計算大小") { model.recalculateTemplateSize(template) }
                        Button("在 Finder 顯示") { model.revealTemplate(template) }
                        Button("壓縮匯出…") { model.exportTemplate(template) }
                        Divider()
                        Button("刪除…", role: .destructive) { templateToDelete = template }
                    }
                    .fixedSize()
                }
            }
            if !model.settings.templates.isEmpty {
                LabeledContent("總共佔用") {
                    let total = model.settings.templates.compactMap(\.sizeBytes).reduce(0, +)
                    Text(SandboxManager.formatBytes(total))
                }
            }
            LabeledContent("下次儲存到") {
                Text(model.settings.effectiveTemplateBaseDir)
                    .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            }
            HStack {
                Button("選擇資料夾…") { model.chooseTemplateDir() }
                Button("使用預設（家目錄）") { model.useDefaultTemplateDir() }
                    .disabled(model.usingDefaultTemplateDir)
                Spacer()
                Button("匯入範本…") { model.importTemplate() }
            }
        }
        .disabled(model.busy)
    }

    private var logSection: some View {
        Section("記錄") {
            ScrollView {
                Text(model.log.isEmpty ? " " : model.log)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 140)
            if model.busy { ProgressView().controlSize(.small) }
        }
    }
}
