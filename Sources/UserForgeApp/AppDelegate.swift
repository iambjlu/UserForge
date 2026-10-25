import AppKit
import Combine

/// 處理退出詢問，以及「選單列圖示存在、視窗又關掉時隱藏 Dock 圖標」。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = ViewModel.shared

        // 轉發或工作狀態改變時，重新決定要不要顯示 Dock 圖標
        model.$forwarding
            .combineLatest(model.$currentTask)
            .sink { [weak self] _ in self?.scheduleActivationPolicyUpdate() }
            .store(in: &cancellables)

        // 視窗關閉、最小化、顯示時也要重新決定
        let center = NotificationCenter.default
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleActivationPolicyUpdate() }
            }
        }
    }

    /// 關掉視窗不退出：待命時留在 Dock，轉發或工作中縮到選單列
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 有開轉發或正在工作時才詢問；待命狀態直接退出
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = ViewModel.shared
        guard model.isActive else { return .terminateNow }

        var details: [String] = []
        if model.forwarding { details.append("埠轉發正在執行，結束後轉發會停止。") }
        if let task = model.currentTask { details.append("「\(task)」還沒做完，現在結束可能留下做到一半的使用者或檔案。") }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "UserForge 仍在工作中，要結束嗎？"
        alert.informativeText = details.joined(separator: "\n")
        // 預設按鈕放「取消」，避免不小心按到 Return 就結束
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "結束")

        // 縮在選單列時沒有視窗也沒有 Dock 圖標，要先把自己帶到前面對話框才看得到
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    // MARK: - Dock 圖標

    /// 視窗的關閉通知發出時視窗還算可見，稍等一下再判斷
    private func scheduleActivationPolicyUpdate() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.updateActivationPolicy()
        }
    }

    /// 有選單列圖示（轉發中或工作中）而且沒有任何視窗 → 隱藏 Dock 圖標；其他情況都顯示
    func updateActivationPolicy() {
        let hasWindow = NSApp.windows.contains { window in
            (window.isVisible || window.isMiniaturized)
                && window.styleMask.contains(.titled)
                && !(window is NSPanel)
        }
        let desired: NSApplication.ActivationPolicy = (ViewModel.shared.isActive && !hasWindow) ? .accessory : .regular
        guard NSApp.activationPolicy() != desired else { return }
        NSApp.setActivationPolicy(desired)
        if desired == .regular, hasWindow { NSApp.activate(ignoringOtherApps: true) }
    }
}
