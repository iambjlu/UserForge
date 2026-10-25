# UserForge

macOS 的使用者建立與管理工具。建立使用者、備份與還原任何使用者的家目錄、複製使用者，
並可把本機螢幕共享埠轉發到別的埠。有圖形介面，也有命令列。

## 功能

- **建立使用者**：可自訂帳號、姓名、密碼、是否管理員、家目錄位置，並可套用範本。
  預設帳號是 `sandbox日期`（例如 `sandbox20261025`），重名才加 `a`、`b`…
- **建立時的選項**：略過設置嚮導，以及 Dock、Finder、外觀、輔助使用等偏好設定，寫進新使用者自己的設定，不影響其他人。
- **範本**：把任何使用者的家目錄備份成有名字的範本，同一個帳號可以存很多份；建立使用者時選一份套用，
  或還原到現有使用者。範本可壓縮匯出成 zip，也能匯入。
- **複製使用者**：把任何現有使用者複製成新使用者。
- **刪除使用者**：不能刪目前使用者，也不能刪最後一個管理員。本程式不記錄建立過哪些使用者。
- **埠轉發**：把 `127.0.0.1:5910` 轉到 `127.0.0.1:5900`（可改），用螢幕共享連同一台電腦的不同使用者很方便。
- **選單列**：轉發中或工作進行中才會出現選單列圖示，關掉視窗會隱藏 Dock 圖標；這時退出會先詢問。待命時什麼都不留。

## 需求

- macOS 13 以上（開發與測試於 macOS 15 / 27）
- 執行 App 的使用者必須是管理員（建立與刪除使用者需要 `sudo`）
- 建議授予 **完整磁碟取用權限**，否則備份、還原其他使用者的受保護資料夾會失敗；App 會偵測並提示

## 編譯

```bash
./build_app.sh          # 產生 build/UserForge.app
./build_app.sh --clean  # 先清掉再編譯
```

只需要 Xcode 命令列工具。`build/` 底下只有 `UserForge.app`。

## 使用

### 圖形介面

開啟 `UserForge.app`。第一次執行需要管理員權限的操作時會詢問管理員密碼，驗證後存進登入鑰匙圈，之後不再詢問
（可在「設定」按「忘記」清除）。

### 命令列

命令列工具在 App 裡面：

```bash
UserForge.app/Contents/Helpers/userforge            # 顯示完整用法
UserForge.app/Contents/Helpers/userforge users      # 列出本機使用者
UserForge.app/Contents/Helpers/userforge create     # 建立使用者
UserForge.app/Contents/Helpers/userforge clone <來源帳號> [新帳號]
UserForge.app/Contents/Helpers/userforge save <帳號> --name 我的範本
UserForge.app/Contents/Helpers/userforge doctor     # 檢查權限
```

管理員密碼依序取自環境變數 `SANDBOX_ADMIN_PASSWORD`、鑰匙圈、終端機詢問。

## 資料位置

- 設定檔與預設範本目錄：`~/Library/Application Support/UserForge/`
- 範本可以改存到其他資料夾，在介面的「範本」區選擇
- 從舊版（資料夾叫 `SandboxMac`）升級時會自動搬遷

## 注意事項

- 範本與匯出的 zip 包含完整家目錄，可能有密碼、金鑰、瀏覽器登入狀態，請妥善保管。
- 只匯入你信任的範本：內容會原樣還原到使用者，包含會自動啟動的程式。
- 複製或還原的登入鑰匙圈只能用來源帳號的密碼解鎖；新使用者密碼不同時，登入後會跳出鑰匙圈密碼提示。
- 帳號登入中時備份或複製，檔案可能仍在變動，建議先登出。
- App 使用 ad-hoc 簽章，每次重新編譯後 macOS 可能再問一次鑰匙圈存取與完整磁碟取用權限。

架構與內部細節見 [Readme_Architecture.md](Readme_Architecture.md)。
