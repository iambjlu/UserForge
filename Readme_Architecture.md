# UserForge 專案架構

macOS 的「使用者建立與管理工具」：建立使用者（可套用範本、可在建立時套用偏好設定）、備份與還原任意使用者的家目錄、
複製使用者、匯出與匯入範本，另外附帶把本機螢幕共享埠轉發到別的埠的功能。
圖形介面（SwiftUI）與命令列共用同一套核心程式。

- 平台：macOS 13 以上，Swift 5.9（SwiftPM，語言模式 Swift 5）
- 不使用任何第三方套件

## 目錄結構

```
UserForge/
├── Package.swift                 三個 target：UserForgeCore（函式庫）、userforge（命令列）、UserForgeApp（App）
├── build_app.sh                  編譯並打包 build/UserForge.app（ad-hoc 簽章）
├── Resources/AppIcon.icns        App 圖標（由 scripts/make_icon.swift 產生，已納入版本控制）
├── scripts/make_icon.swift       用 CoreGraphics 畫圖標並輸出 .icns
└── Sources/
    ├── UserForgeCore/            核心邏輯（圖形介面與命令列共用）
    ├── userforge/main.swift      命令列
    └── UserForgeApp/             SwiftUI 圖形介面
```

## build_app.sh 與打包

- `swift build -c release` 之後組出 `build/UserForge.app`：主程式 `Contents/MacOS/UserForge`、
  命令列工具 `Contents/Helpers/userforge`、圖標 `Contents/Resources/AppIcon.icns`、`Info.plist`（寫在腳本內）。
- 命令列工具**不能**放在 `Contents/MacOS/`：macOS 預設檔案系統不分大小寫，`userforge` 會蓋掉主程式 `UserForge`。
  腳本在複製後用 `cmp` 檢查兩個執行檔不同。
- `build/` 底下只會有 `UserForge.app`，不產生其他檔案；舊版留下的 `SandboxMac.app`、`userforge`、`sandboxctl` 會被清掉。
- 圖標檔不存在時會自動呼叫 `scripts/make_icon.swift` 重畫。`--clean` 先清掉 `.build` 與 `build`。
- 簽章：`codesign --force --deep --sign -`，之後 `--verify --deep --strict`。

## UserForgeCore

### Shell.swift
- `Shell.run(path, args, input:)`：執行外部程式，收集 stdout / stderr，路徑必須是完整路徑。
- `Privileged.run(command, allowFailure:)`：以 root 執行。已是 root 就直接執行，否則 `sudo -k -S -p ""`，
  密碼只經由 stdin 傳遞，不放在參數裡。密碼錯誤丟出「管理員密碼錯誤」。
  失敗訊息含 `Operation not permitted` / `Permission denied` 時會附上完整磁碟取用權限的提示。
- `SandboxError`：帶中文訊息的錯誤。

### Settings.swift
- `TemplateRecord`：一份範本（id、名稱、完整路徑、儲存時間、來源帳號、來源 GeneratedUID、佔用大小）。
- `SandboxSettings`：密碼、埠、名稱前綴（`namePrefix`，預設 `sandbox`，介面不再提供設定）、是否管理員、
  是否略過設置嚮導、`tweaks`（建立時要套用的偏好設定，id → 值，有出現就代表啟用）、家目錄上層資料夾、
  範本目錄、範本清單與預設範本。**不記錄建立過哪些使用者**；舊版設定檔的 `sandboxes` 欄位讀取時被忽略，下次儲存就消失。
  舊版只有單一範本的欄位（`templatePath` 等）會在讀取時轉成範本清單的第一筆。
- `SettingsStore`：設定存在 `~/Library/Application Support/UserForge/settings.json`（也是預設的範本目錄）。
  環境變數 `SANDBOX_CONFIG_DIR` 可指定別的資料夾（測試用）。
  首次讀取時，若舊資料夾 `SandboxMac` 存在而 `UserForge` 不存在，直接把整個資料夾改名，
  並把設定檔裡範本路徑的舊前綴改成新路徑；使用 `SANDBOX_CONFIG_DIR` 時不做搬遷。

### Tweaks.swift
- `Tweak.catalog`：建立使用者時可套用的偏好設定清單（外觀、降低透明度、減少動態效果、視窗動畫、
  Dock 各項、Finder 各項、iCloud 存檔、長按選單、Stage Manager 等），每項有偏好設定檔名、鍵、型別（開關 / 選項 / 整數）。
- 全部寫進**新使用者自己**的 `~/Library/Preferences`，不動系統層級（/Library）設定。
- `normalizedValue` 驗證值是否合法，避免寫入任意字串。選項值為空字串代表「刪除這個設定」。

### AdminCredential.swift
- 管理員密碼存在登入鑰匙圈（service `local.userforge.admin`，account 為目前使用者）。
- `load` 讀不到新項目時改讀舊項目 `local.sandboxmac.admin`，讀到後搬到新項目。
- `verify` 用 `sudo -k -S -v` 驗證密碼；`save` 前一定要先驗證。

### Permissions.swift
- `FullDiskAccess.isGranted`：嘗試開啟 `/Library/Application Support/com.apple.TCC/TCC.db`，`EPERM` / `EACCES` 代表沒有授權。
  以 sudo 啟動的子程序沿用 App 的授權，所以檢查 App 自己即可。
- 提供系統設定的 URL 與提示文字。

### PortForwarder.swift
- 用 Network framework 在 `127.0.0.1:<轉發埠>` 監聽，轉發到 `127.0.0.1:<來源埠>`。
- 支援 TCP 半關閉：兩個方向都送完 EOF 才關閉連線。

### SandboxManager.swift
所有會改動系統的操作都在這裡，以 `Privileged` 執行。
- **LocalUser / localUsers()**：列出本機一般使用者（uid ≥ 500、名稱不以 `_` 開頭），含姓名、家目錄、是否管理員
  （`dseditgroup`）、是否登入中（有該 uid 的 Dock 程序）、是否為目前使用者。
- **create**：驗證帳號與前綴 → 解析範本 → `sysadminctl -addUser` → 建立家目錄 → 套用範本 → 略過設置嚮導 → 套用偏好設定。
  預設帳號是 `前綴 + 日期`（例如 `sandbox20261025`），已存在才依序加 `a`、`b`…、`aa`…。姓名預設同帳號。
- **skipSetupAssistant**：寫入 `com.apple.SetupAssistant` 的一批 `DidSee*` 鍵，並把 `LastSeenCloudProductVersion`、
  `LastSeenBuddyBuildVersion` 設成目前系統版本。範本還原與複製後會再做一次。
- **applyTweaks**：依 `Tweak.catalog` 把勾選項目一次寫進新使用者的偏好設定（單一 sudo、參數以位置參數傳入）。
- **cloneUser**：以乾淨環境建立新使用者後，把來源家目錄 `ditto` 過去、移除快取、處理鑰匙圈資料夾、再套用略過嚮導與偏好設定。
- **restoreTemplate(_:to:)**：把範本還原到現有使用者（覆蓋同名檔案，不刪多餘檔案）；對象必須已登出。
- **saveTemplate**：備份任意一般使用者。範本放在 `<範本目錄>/UserForgeTemplate-<id>/`（`home/` 與 `template.json`，root 擁有、權限 700），
  先備份到 `.new` 再換上；同名覆蓋、不同名稱可以存很多份。`deleteUser` 時才會先強制登出並在備份後刪除；其他情況不結束對方程序，只提醒。
  範本目錄不能放在要備份的家目錄裡。
- **匯出 / 匯入**：`ditto -c -k` 壓成 zip（內含 `template.json`，權限 600）。匯入先用 `zipinfo` 擋掉絕對路徑與 `..`，
  再以目前使用者身分解壓縮到暫存位置，最後由 root 搬進範本目錄；同名自動加編號。
- **delete**：刪除使用者不限於本程式建立的（本程式不記錄也不標記）。保護：必須是一般帳號、不能刪目前使用者、
  不能刪最後一個管理員；只清除路徑最後一段剛好等於帳號的殘留家目錄。沒有批次刪除。
- **範本管理**：重新命名、刪除、重新計算大小（`du -sk`）。刪除只接受名稱以 `UserForgeTemplate`（或舊的 `SandboxMacTemplate`）開頭的資料夾。
- 家目錄位置：可指定上層資料夾，家目錄為 `<上層>/<帳號>`；拒絕 `/`、`/System` 等系統目錄與含 `..` 的路徑。
- 登出使用者：`launchctl bootout gui/<uid>`、`user/<uid>`，再 `pkill -KILL -u <uid>`。

## userforge（命令列）

`Sources/userforge/main.swift`。主要指令：`doctor`、`users`、`status`、`create`、`clone`、`restore`、`save`、`delete`、
`tweaks`、`tweak`、`templates`、`template-use`、`template-rename`、`template-size`、`template-export`、`template-import`、
`template-delete`、`config`、`forward`。不帶參數會印出完整用法。
管理員密碼來源順序：環境變數 `SANDBOX_ADMIN_PASSWORD` → 鑰匙圈 → 終端機詢問。
App 內的路徑：`UserForge.app/Contents/Helpers/userforge`。

## UserForgeApp（SwiftUI）

### UserForgeApp.swift
- `Window("UserForge", id: "main")` 單一視窗，加上 `MenuBarExtra`。
- 選單列圖示只在 `ViewModel.isActive`（轉發中或有工作進行）時插入；內容：狀態文字、顯示視窗、停止轉發、結束。
  文字用 `String` 組合，避免埠號被格式化成 `5,910`。

### AppDelegate.swift
- `applicationShouldTerminate`：`isActive` 時跳出詢問（預設按鈕是「取消」）；待命時直接退出。
- `applicationShouldTerminateAfterLastWindowClosed` 為 false。
- Dock 圖標：有選單列圖示且沒有任何可見或最小化的標題視窗時切成 `.accessory`（隱藏 Dock 圖標），其他情況 `.regular`。
  由轉發 / 工作狀態與視窗關閉、最小化、顯示事件觸發重新判斷。

### ViewModel.swift
- 單例 `ViewModel.shared`（AppDelegate、選單列與視窗共用）。
- 所有操作經過 `run`：沒有管理員密碼就跳出密碼對話框，驗證後存鑰匙圈並接著執行；密碼失效時自動清掉。
  每次操作結束重新讀取設定與使用者清單。
- `currentTask` 只在需要管理員權限的實際工作期間有值，啟動時的重新整理不算（避免選單列圖示閃一下、誤觸退出詢問）。
- 帳號 / 姓名輸入框預設帶入建議值，手動改過就不再自動更新。

### ContentView.swift
由上到下：權限橫幅（沒有完整磁碟取用權限時）、設定（管理員密碼）、埠轉發、建立新使用者（含「選項…」彈出視窗）、
使用者（每個使用者的「操作」選單：備份、備份並刪除、複製、還原範本、刪除）、範本、記錄。

## 資料位置

| 項目 | 位置 |
|---|---|
| 設定檔與預設範本目錄 | `~/Library/Application Support/UserForge/` |
| 範本 | `<範本目錄>/UserForgeTemplate-<id>/{home, template.json}`（root 擁有，700） |
| 管理員密碼 | 登入鑰匙圈，service `local.userforge.admin` |
| 命令列工具 | `UserForge.app/Contents/Helpers/userforge` |

## 環境變數

- `SANDBOX_ADMIN_PASSWORD`：命令列用的管理員密碼。
- `SANDBOX_CONFIG_DIR`：改用別的設定與範本資料夾，同時停用舊資料夾搬遷。**測試時一律要設**，否則會動到真實設定。

## 測試方式

- 破壞性測試在測試機執行，不在開發機執行；測試一律設定 `SANDBOX_CONFIG_DIR`，測試帳號用 `zztest` 開頭，結束後清除。
- 程式從系統帳號資料取得家目錄，`HOME` 環境變數無效；要測家目錄相關行為需建立臨時帳號，用 `sudo -u` 執行。
- 測試機的編譯目錄放在 `/tmp`，不在家目錄或桌面留下檔案。
