import SwiftUI

@main
struct UserForgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ViewModel.shared

    var body: some Scene {
        // 單一視窗。關掉之後可以從選單列的「顯示視窗」再開
        Window("UserForge", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 520, minHeight: 640)
        }

        // 只有轉發中或工作中才插入選單列；待命時整個消失
        MenuBarExtra(
            "UserForge",
            systemImage: "person.2.fill",
            isInserted: Binding(get: { model.isActive }, set: { _ in })
        ) {
            MenuBarContent(model: model)
        }
    }
}

private struct MenuBarContent: View {
    @ObservedObject var model: ViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // 用 String 組字串，避免埠號被格式化成 5,910
        if model.forwarding {
            Text(verbatim: "轉發中：localhost:" + String(model.settings.forwardPort) + " ← " + String(model.settings.sourcePort))
        }
        if let task = model.currentTask {
            Text(verbatim: "工作中：" + task)
        }
        Divider()
        Button("顯示視窗") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        if model.forwarding {
            Button("停止轉發") { model.toggleForward() }
        }
        Divider()
        Button("結束 UserForge") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
