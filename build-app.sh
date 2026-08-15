#!/bin/bash
# ------------------------------------------------------------------
# 留刻 · Swift 版打包脚本
#   swift build (release) → 手工组装 .app bundle → ad-hoc 签名 → 冒烟校验
#
# ⚠️ bundle id 永远是 app.memento.lens —— 改了 macOS 录屏授权就要重授权
# ------------------------------------------------------------------
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

APP_NAME="留刻"
BUNDLE_ID="app.memento.lens"
VERSION="1.0.0"
APP="$DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

echo "==> 1/5 编译（release）"
swift build -c release --disable-sandbox
BIN="$(swift build -c release --disable-sandbox --show-bin-path)/Liuke"
[ -f "$BIN" ] || { echo "!! 找不到产物：$BIN"; exit 1; }

echo "==> 2/5 组装 bundle"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

cp "$BIN" "$MACOS/$APP_NAME"
chmod +x "$MACOS/$APP_NAME"

# ---- 资源（必需，失败必须当场报错，不要 2>/dev/null || true）----
cp "$DIR/Resources/brand-logo.png"       "$RES/"
cp "$DIR/Resources/trayTemplate.png"     "$RES/"
cp "$DIR/Resources/trayTemplate@2x.png"  "$RES/"
cp "$DIR/Resources/icon.icns"            "$RES/"
cp "$DIR/Resources/icon.png"             "$RES/"
cp "$DIR/Resources/WeChat.png"           "$RES/"

echo "==> 3/5 写 Info.plist"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>        <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key>           <string>$VERSION</string>
  <key>CFBundleIconFile</key>          <string>icon</string>
  <key>LSMinimumSystemVersion</key>    <string>26.0</string>
  <key>LSApplicationCategoryType</key> <string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSHumanReadableCopyright</key>  <string>© 2026 留刻 · 本地运行，数据不出本机</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key> <true/>
  </dict>
</dict>
</plist>
PLIST

printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "==> 4/5 签名"
# ⚠️ 必须先清扩展属性：源资源带 com.apple.FinderInfo / quarantine 时
#    codesign 会报 "resource fork, Finder information, or similar detritus not allowed"
xattr -cr "$APP"
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

echo "==> 5/5 自检"
for f in brand-logo.png trayTemplate.png "trayTemplate@2x.png" icon.icns WeChat.png; do
  [ -f "$RES/$f" ] || { echo "!! 缺资源：$f"; exit 1; }
done
# PNG 必须能真正解码（历史坑：头正常但 IDAT 损坏）
for f in trayTemplate.png "trayTemplate@2x.png" brand-logo.png WeChat.png; do
  sips -g pixelWidth "$RES/$f" >/dev/null 2>&1 || { echo "!! PNG 损坏：$f"; exit 1; }
done
echo "    资源 OK"
du -sh "$APP" | awk '{print "    体积 " $1}'

echo ""
echo "✅ 打包完成：$APP"
echo "   启动：open \"$APP\""
