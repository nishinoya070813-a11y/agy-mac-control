#!/bin/bash
# AGY Mac Control 安装脚本：从源码编译菜单栏小程序，并在 Antigravity 里登记 MCP 插件。
# 不下载任何东西，只用 macOS 自带的 swiftc / codesign / python3。
set -euo pipefail

cd "$(dirname -- "$0")"
APP_NAME="AGY Mac Control"
APP="/Applications/${APP_NAME}.app"
BUNDLE_ID="local.agy-mac-control"
SUPPORT="$HOME/Library/Application Support/agy-mac-control"
MCP_CONFIG="$HOME/.gemini/config/mcp_config.json"

echo "== AGY Mac Control 安装 =="

if [ "$(uname)" != "Darwin" ]; then echo "只支持 macOS"; exit 1; fi
major=$(sw_vers -productVersion | cut -d. -f1)
if [ "$major" -lt 14 ]; then echo "需要 macOS 14 或更新版本"; exit 1; fi
command -v swiftc >/dev/null || { echo "找不到 swiftc：请先运行 xcode-select --install 安装命令行工具"; exit 1; }
command -v python3 >/dev/null || { echo "找不到 python3：请先运行 xcode-select --install"; exit 1; }

echo "1/4 编译菜单栏小程序…"
pkill -f "${APP}/Contents/MacOS/AGYMacControl" 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
<key>CFBundleName</key><string>${APP_NAME}</string>
<key>CFBundleDisplayName</key><string>${APP_NAME}</string>
<key>CFBundleExecutable</key><string>AGYMacControl</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
swiftc -O -o "$APP/Contents/MacOS/AGYMacControl" helper/Helper.swift -framework Cocoa -framework Network

echo "2/4 本机签名（临时签名，只在你这台电脑上用）…"
codesign --force --deep -s - "$APP"

echo "3/4 安装 MCP 插件…"
mkdir -p "$SUPPORT"
cp mcp/mcp_server.py "$SUPPORT/mcp_server.py"
chmod 700 "$SUPPORT"

echo "4/4 在 Antigravity 里登记插件（会先备份原配置）…"
mkdir -p "$(dirname "$MCP_CONFIG")"
[ -s "$MCP_CONFIG" ] && cp "$MCP_CONFIG" "$MCP_CONFIG.bak.$(date +%s)"
python3 - "$MCP_CONFIG" "$SUPPORT/mcp_server.py" <<'PY'
import json, os, sys
path, server = sys.argv[1], sys.argv[2]
cfg = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
cfg.setdefault("mcpServers", {})["agy-mac-control"] = {"command": "/usr/bin/python3", "args": [server]}
with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY

# 旧的授权记录在重新编译后会失效，先清掉，让系统重新弹出授权
tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1 || true
open "$APP"

cat <<'TXT'

✅ 安装完成。接下来请你自己做（只有你能点）：
  1. 系统设置 → 隐私与安全性 → 辅助功能：打开「AGY Mac Control」
  2. 系统设置 → 隐私与安全性 → 屏幕与系统录音：打开「AGY Mac Control」
     （列表里没有就点“+”从“应用程序”里添加）
  3. 在菜单栏 🖱 AG → 退出，再重新打开 /Applications/AGY Mac Control.app
  4. 重启 Antigravity，让它加载插件

用法：在 Antigravity 里直接说“打开计算器，帮我算 7+8”。按 Esc 随时暂停。
TXT
