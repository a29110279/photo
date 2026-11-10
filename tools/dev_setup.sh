#!/usr/bin/env bash
# AI 輔助開發工具建置（評估文件第 2.1 節）。只影響開發環境，不會打包進 App。
# 需求：uv、Node.js(npm)。在專案根目錄執行：bash tools/dev_setup.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== Graphify =="
uv tool install graphifyy
graphify install          # 註冊 skill 到 AI 助理
graphify claude install   # 讓助理優先查圖譜
graphify hook install     # commit / 切換分支時自動重建圖譜

echo "== GitNexus =="
npm install -g gitnexus
gitnexus analyze          # 建立索引、安裝 agent skills、產生 CLAUDE.md / AGENTS.md
gitnexus setup            # 一次性設定編輯器的 MCP

cat <<'MSG'

完成。後續請手動處理：
  1. 在 AI 助理中執行 /graphify . 建立第一份圖譜
  2. 檢查並合併兩個工具寫入 CLAUDE.md 的指示，避免互相衝突
  3. 不要使用 gitnexus wiki 的雲端 LLM；若要用，API Key 只放環境變數
MSG
