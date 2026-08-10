#!/bin/bash
# 把 SPM 可执行文件打成可双击运行的 .app bundle。
# 菜单栏应用必须走 bundle：LSUIElement 只能写在 Info.plist 里，
# 而且没有 bundle 就拿不到稳定的 bundle identifier（辅助功能授权按它记录）。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${1:-release}
APP="build/Clipflow.app"
BIN=".build/${CONFIG}/ClipflowApp"

echo "▶ 编译（${CONFIG}）"
# 全量编译，不要只编 App —— 只编 App 会让 CLI 停留在旧版本，
# 而 CLI 正是验证行为的工具，用过期的工具验证会得出错误结论（踩过一次）。
swift build -c "$CONFIG"

echo "▶ 组装 bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Clipflow"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Clipflow</string>
    <key>CFBundleDisplayName</key>       <string>Clipflow</string>
    <key>CFBundleExecutable</key>        <string>Clipflow</string>
    <key>CFBundleIdentifier</key>        <string>com.tomeageer.clipflow</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <!-- 菜单栏常驻，不进 Dock、不显示在 Cmd-Tab -->
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

# 本机自签名。没有 Developer ID 也能自己用；分发给别人需要正式签名+公证。
echo "▶ 签名（ad-hoc）"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (签名跳过)"

echo
echo "✅ 完成：$(pwd)/$APP"
echo
echo "运行：  open $APP"
echo "热键：  ⌘⇧V 唤出面板"
echo "退出：  菜单栏图标 → 退出 Clipflow"
echo
echo "首次自动粘贴需要在「系统设置 → 隐私与安全性 → 辅助功能」里勾选 Clipflow。"
echo "没授权也能用：面板会把内容放进剪贴板，你手动 ⌘V。"
