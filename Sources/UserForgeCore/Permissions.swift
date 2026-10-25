import Foundation

public enum FullDiskAccess {
    /// TCC 資料庫只有擁有「完整磁碟取用權限」的程序才讀得到，用它來判斷最準。
    /// 以 sudo 啟動的子程序（ditto 等）會沿用 App 的授權，所以檢查 App 自己即可。
    public static var isGranted: Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 {
            close(fd)
            return true
        }
        return errno != EPERM && errno != EACCES
    }

    /// 在系統設定開啟「完整磁碟取用權限」頁面
    public static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

    public static let hint = "需要在「系統設定 → 隱私權與安全性 → 完整磁碟取用權限」授予 UserForge（命令列則是授予執行它的終端機），授予後重新啟動。"
}
