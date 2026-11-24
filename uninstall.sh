#!/bin/bash
# AGY Mac Control 卸载脚本：删掉小程序、插件文件、Antigravity 里的登记和系统授权记录。
set -euo pipefail

APP="/Applications/AGY Mac Control.app"
BUNDLE_ID="local.agy-mac-control"
SUPPORT="$HOME/Library/Application Support/agy-mac-control"
MCP_CONFIG="$HOME/.gemini/config/mcp_config.json"

pkill -f "${APP}/Contents/MacOS/AGYMacControl" 2>/dev/null || true
rm -rf "$APP" "$SUPPORT"

if [ -s "$MCP_CONFIG" ]; then
  python3 - "$MCP_CONFIG" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    cfg = json.load(f)
cfg.get("mcpServers", {}).pop("agy-mac-control", None)
with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
fi

tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1 || true
echo "✅ 已卸载。重启 Antigravity 后插件就不会再出现。"
