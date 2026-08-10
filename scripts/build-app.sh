#!/bin/bash
# 把 SPM 可执行文件打成可双击运行的 .app bundle。
# 菜单栏应用必须走 bundle：LSUIElement 只能写在 Info.plist 里，
# 而且没有 bundle 就拿不到稳定的 bundle identifier（辅助功能授权按它记录）。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${1:-release}
APP="build/Clipflow.app"
BIN=".build/${CONFIG}/ClipflowApp"

echo "编译（${CONFIG}）"
# 全量编译，不要只编 App —— 只编 App 会让 CLI 停留在旧版本，
# 而 CLI 正是验证行为的工具，用过期的工具验证会得出错误结论（踩过一次）。
swift build -c "$CONFIG"

echo "组装 bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Clipflow"

# 图标
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 本地化资源包。SPM 把 .lproj 打进 <Package>_<Target>.bundle，
# 必须一并拷进 Resources，否则 App 里所有文案会退回 key 名。
for b in ".build/${CONFIG}"/*.bundle; do
  [ -e "$b" ] || continue
  cp -R "$b" "$APP/Contents/Resources/"
done

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
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundleDevelopmentRegion</key> <string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>zh-Hans</string></array>
    <key>NSHumanReadableCopyright</key>  <string>MIT License · Copyright (c) 2026 TomEageer</string>
</dict>
</plist>
PLIST

# 必须用稳定身份签名，不能用 ad-hoc。
#
# ad-hoc 签名的「指定要求」绑在二进制哈希（cdhash）上，每次重编都变
#   -> 系统认为这是另一个 App
#   -> 之前授予的辅助功能权限直接失效，
#      而系统设置里那条记录还在，看着像已授权，实际不生效。
# 开发期反复重编时这个坑极其隐蔽 —— 用户会以为是 App 没刷新状态。
#
# 用 Apple Development 证书签名后，指定要求基于证书 + bundle id，
# 重编不影响，授权一次就长期有效。
IDENTITY=""
if security find-identity -v -p codesigning 2>/dev/null | grep -q 'Apple Development'; then
  IDENTITY=$(security find-identity -v -p codesigning | grep 'Apple Development' | head -1 | sed 's/.*"\(.*\)".*/\1/')
fi

if [ -n "$IDENTITY" ]; then
  echo "签名：$IDENTITY"
  codesign --force --deep --sign "$IDENTITY" "$APP"
  codesign -d -r- "$APP" 2>&1 | grep designated | sed 's/^/    /' || true
else
  echo "签名：ad-hoc（每次重编都会让辅助功能授权失效）"
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
fi

echo
echo "完成：$(pwd)/$APP"
echo
echo "运行：  open $APP"
echo "热键：  Cmd+Shift+V 唤出面板"
echo
echo "首次自动粘贴需要在「系统设置 -> 隐私与安全性 -> 辅助功能」勾选 Clipflow。"
echo "没授权也能用：面板会把内容放进剪贴板，你手动 Cmd+V。"
echo
echo "若之前给 ad-hoc 版本授过权，需在系统设置里把旧的 Clipflow 条目"
echo "选中按 - 删掉，再重新添加一次。之后重编不会再失效。"
