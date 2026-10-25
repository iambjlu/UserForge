#!/bin/bash
# 編譯並打包 UserForge.app（ad-hoc 簽章）。
#
#   ./build_app.sh            編譯 release 並產生 build/UserForge.app
#   ./build_app.sh --clean    先清掉 .build 與 build 再編譯
#
# 命令列工具 userforge 放在 App 裡面（UserForge.app/Contents/Helpers/userforge），
# build/ 底下除了 UserForge.app 之外不會有任何其他檔案。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="UserForge"
BUNDLE_ID="local.userforge.app"
APP="build/$APP_NAME.app"

if [[ "${1:-}" == "--clean" ]]; then
    rm -rf .build build
fi

# 圖標：Resources/AppIcon.icns 不存在就用腳本重新畫一個
if [[ ! -f Resources/AppIcon.icns ]]; then
    mkdir -p Resources
    swift scripts/make_icon.swift Resources/AppIcon.icns
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

# 重新打包，並清掉舊版留下的東西（改名前的 App、散落在旁邊的命令列檔）
rm -rf "$APP" build/SandboxMac.app build/userforge build/sandboxctl
# 注意：macOS 預設檔案系統不分大小寫，userforge 不能放在 MacOS/ 裡，否則會蓋掉主程式 UserForge
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/UserForgeApp" "$APP/Contents/MacOS/$APP_NAME"
cp "$BIN/userforge" "$APP/Contents/Helpers/userforge"
if cmp -s "$APP/Contents/MacOS/$APP_NAME" "$APP/Contents/Helpers/userforge"; then
    echo "錯誤：主程式與命令列工具內容相同，打包出錯" >&2
    exit 1
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "完成: $APP"
echo "命令列工具: $APP/Contents/Helpers/userforge"
