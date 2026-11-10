# 提示詞篩選相片／影片 App — 專案評估

> 版本：v0.3（新增 AI 輔助開發工具：Graphify、GitNexus）
> 日期：2026-11-10
> 開發框架：Flutter（iOS / Android 雙平台同時開發）
> 用途：個人使用，不上架

---

## 0. 決策紀錄

| 項目 | 決定 | 影響 |
|---|---|---|
| 目標平台 | 雙平台同時上線 | 維持 iOS / Android 並行開發 |
| 雲端 LLM（O4） | 完全不用雲端 | O4 改為裝置端規則式解析；不需後端、無 API 費用與金鑰管理 |
| 人臉分群（O12） | 保留在 Phase 3 | 維持原規劃 |
| MVP 範圍 | O1、O2、O3 全部列入 | O3 改為「照片資料不離開裝置」的設計原則 |
| 模型提供方式 | 首次啟動時下載 | 新增 C12 模型下載管理；安裝檔維持小巧 |
| 照片量級 | 約 1 萬張以內 | 向量儲存改用 `sqflite` + 暴力計算，不需向量索引 |
| 商業模式 | 個人使用／不上架 | 移除上架準備，改為個人安裝部署 |
| AI 輔助開發工具 | 建置專案時加入 Graphify 與 GitNexus | 新增第 2.1 節；Phase 0 增加 0.3 週工具建置 |

---

## 1. 專案概述

以自然語言提示詞（例如「去年在日本拍的海邊影片」）篩選手機內的相片與影片，並可在手機內建立相簿，把篩選結果加入或搬移進去。

**核心原則**
- 以語意搜尋取代手動滑相簿
- **全裝置端運算**：照片與搜尋內容不離開裝置（唯一的網路行為是首次下載模型）
- 篩選結果可一鍵整理成相簿

---

## 2. 技術選型

| 領域 | 選用技術 | 備註 |
|---|---|---|
| 媒體存取 | `photo_manager` | iOS PhotoKit / Android MediaStore |
| 相簿操作 | `photo_manager` editor API + Platform Channel（Kotlin） | Android 批次授權需 `MediaStore.createWriteRequest` |
| 語意模型 | 多語 CLIP 系列（MobileCLIP / SigLIP multilingual / Chinese-CLIP） | 需 PoC 驗證中文效果 |
| 推論引擎 | `tflite_flutter`（LiteRT）或 ONNX Runtime | iOS 可選 Core ML 加速 |
| 模型下載 | `dio`（支援斷點續傳）+ SHA-256 校驗 | 模型放在公開靜態空間（如 GitHub Releases），不需任何金鑰 |
| 向量儲存 | `sqflite` / `drift` 存 embedding（BLOB）+ 暴力計算 | 1 萬張 × 512 維約 20 MB，單次比對可在 100ms 內完成 |
| 提示詞解析 | 裝置端規則式解析器 | 日期、地點、媒體類型關鍵字 → 結構化條件 |
| Metadata | EXIF（日期、GPS）、媒體類型、影片長度 | GPS 需反向地理編碼（可用平台原生 Geocoder） |
| 輔助辨識 | Google ML Kit（OCR、Face Detection、Image Labeling） | 皆為裝置端；人臉辨識需另接 MobileFaceNet |
| 影片抽幀 | `video_thumbnail` 或原生 API | 每 N 秒抽一幀 |
| 背景處理 | Isolate、`workmanager`（Android）、BGProcessingTask（iOS） | iOS 背景執行受限 |
| 狀態管理 | Riverpod 或 Bloc | — |
| 本地資料庫 | `drift`（SQLite） | 索引狀態、embedding、操作日誌、智慧相簿規則 |

### 2.1 AI 輔助開發工具（開發環境用，不打包進 App）

兩者都是把程式碼庫轉成**知識圖譜**，讓 AI 程式助理（如 Claude Code）先查圖譜再讀檔，以減少 token 消耗並避免改壞相依程式碼。它們只存在開發環境，**不會出現在 `pubspec.yaml`，也不影響 App 本身**。

| 項目 | Graphify | GitNexus |
|---|---|---|
| 定位 | 程式碼 + 文件 + PDF 等任意資料夾 → 知識圖譜 | 程式碼 → 知識圖譜，強調呼叫鏈與變更影響分析 |
| 本專案用途 | 架構總覽、串連設計文件（本評估檔、PoC 筆記）與程式碼 | 修改前的影響範圍分析（blast radius）、除錯時追蹤呼叫鏈、安全重構 |
| Flutter 支援 | 有 Dart 解析（支援程度需 Phase 0 實測） | 支援 Dart，含 Flutter widget 與 Riverpod 模式偵測；亦支援 Kotlin、Swift（Platform Channel 原生程式碼） |
| 整合方式 | AI 助理 Skill（`/graphify`） | MCP Server + Agent Skills + Claude Code hooks |
| 執行環境 | Python（`uv`） | Node.js（`npm`） |

**建置步驟（Phase 0）**

```bash
# Graphify
uv tool install graphifyy
graphify install            # 註冊 skill 到 AI 助理
# 在 AI 助理中執行：/graphify .
graphify claude install     # 讓助理優先查圖譜
graphify hook install       # commit / 切換分支時自動重建圖譜

# GitNexus（建議全域安裝，避免 npx 冷啟動逾時）
npm install -g gitnexus
gitnexus analyze            # 建立索引、安裝 agent skills、產生 CLAUDE.md / AGENTS.md
gitnexus setup              # 一次性設定編輯器的 MCP
```

**使用規範**
- **分工**：架構理解與文件關聯 → Graphify；改動前影響分析、重構 → GitNexus（其 `detect_impact` 可作為 commit 前檢查）
- **版本控制**：`.gitnexus/`（索引）加入 `.gitignore`；`graphify-out/` 可只保留 `GRAPH_REPORT.md`，其餘忽略
- **CLAUDE.md**：兩個工具都會寫入指示，建置後需人工檢查合併，避免指示互相衝突
- **雲端與金鑰**：
  - GitNexus 的 `wiki` 功能預設呼叫雲端 LLM，需 API Key。建議不使用，或以 `--base-url` 指向本機 Ollama
  - 若仍要用雲端，API Key 一律放環境變數，不寫入任何設定檔或提交到版本控制
  - Graphify 的語意萃取由 AI 助理本身執行，程式碼會送到該助理的服務端（與一般使用 AI 助理相同）
- **定位**：圖譜只是導航，最終仍以原始碼為準

---

## 3. 系統架構

```
UI (Flutter)
 ├─ 搜尋頁 / 結果預覽 / 相簿管理 / 設定
 │
Application Layer (Riverpod)
 ├─ SearchService      ← 規則式提示詞解析 + 混合搜尋
 ├─ AlbumService       ← 建立相簿、加入/搬移、復原
 ├─ IndexingService    ← 背景索引、增量更新
 ├─ ModelService       ← 模型下載、校驗、版本管理
 │
Domain / Infra
 ├─ MediaRepository    ← photo_manager
 ├─ EmbeddingService   ← LiteRT / ONNX（Isolate 執行）
 ├─ LocalStore         ← drift（metadata + embedding）
 └─ Platform Channel   ← Android createWriteRequest、iOS PhotoKit 補強
```

**搜尋流程（混合式，全裝置端）**
1. 規則式解析提示詞，拆成**結構化條件**（日期、地點、類型）與**語意查詢**
2. 以 metadata 先過濾候選集
3. 計算 text embedding，與候選 image embedding 比對 cosine similarity
4. 依門檻值與分數排序並輸出

---

## 4. 功能清單與評估

> 工作量以 **1 位熟悉 Flutter 的開發者**估算，單位為人週（含測試）。
> 優先級：**P0** = MVP 必要、**P1** = 第一次改版、**P2** = 加分功能。

### 4.1 核心功能

| # | 功能 | 優先級 | 工作量 | 難度 | 說明 |
|---|---|---|---|---|---|
| C1 | 權限處理（含 iOS 有限存取、Android 14 部分存取） | P0 | 1 | 中 | 各版本行為差異大 |
| C2 | 媒體瀏覽（縮圖格狀檢視、相片/影片預覽） | P0 | 1 | 低 | — |
| C3 | 模型 PoC（Python 驗證中文提示詞準確度） | P0 | 1 | 中 | **最先執行**，決定模型選型 |
| C4 | 裝置端 embedding 推論（相片） | P0 | 2 | 高 | 模型轉檔、量化、delegate 加速 |
| C5 | 索引管線（Isolate、進度、斷點續做、增量更新） | P0 | 2 | 高 | — |
| C6 | Embedding 儲存與語意搜尋（暴力計算） | P0 | 0.5 | 低 | 1 萬張規模不需向量索引 |
| C7 | 影片抽幀與索引 | P0 | 1.5 | 中 | 多幀取最高分 |
| C8 | Metadata 過濾（日期、類型、GPS） | P0 | 1 | 中 | — |
| C9 | 建立相簿 + 加入（iOS） | P0 | 1 | 中 | iOS 為「加入」，原檔不動 |
| C10 | 建立相簿 + 搬移（Android，含批次授權） | P0 | 1.5 | 高 | 需 Platform Channel |
| C11 | 搜尋結果多選、全選、排除 | P0 | 0.5 | 低 | — |
| C12 | 模型首次下載管理（進度、斷點續傳、校驗、更新） | P0 | 0.5 | 低 | 決策新增 |

**核心小計：13.5 人週**

### 4.2 優化功能

| # | 功能 | 優先級 | 工作量 | 難度 | 價值 | 說明 |
|---|---|---|---|---|---|---|
| O1 | 搬移前預覽 + 操作日誌 + 一鍵復原 | **P0** | 1 | 中 | 高 | Android 會實際移動檔案 |
| O2 | 相關度門檻滑桿 | **P0** | 0.3 | 低 | 高 | 成本極低、體驗提升明顯 |
| O3 | 隱私保證：照片資料不離開裝置 | **P0** | 0 | — | 高 | 因不使用雲端，轉為架構設計原則，無獨立工作量 |
| O4 | 規則式提示詞解析（日期、地點、類型） | P1 | 1.5 | 中 | 高 | 決策調整：不用雲端 LLM，改為裝置端規則；不需後端 |
| O5 | 智慧相簿（儲存規則，新照片自動加入） | P1 | 1.5 | 中 | 高 | 依賴增量索引 |
| O6 | 重複／相似照片偵測 | P1 | 1 | 低 | 高 | 沿用 embedding，額外成本低 |
| O7 | 以圖搜圖 | P1 | 0.5 | 低 | 中 | 沿用 image embedding |
| O8 | 回饋學習（勾掉誤判、補上漏判以修正查詢） | P1 | 1 | 中 | 中 | Rocchio 類方法即可 |
| O9 | OCR 文字搜尋（截圖、收據） | P1 | 1 | 中 | 中 | ML Kit；索引時間會增加 |
| O10 | 模糊照、截圖、螢幕錄影清理 | P2 | 1 | 低 | 中 | Laplacian variance + metadata |
| O11 | 事件自動分群（時間 + GPS） | P2 | 1.5 | 中 | 中 | — |
| O12 | 人臉分群（找出某人的所有照片） | P2 | 3 | 高 | 高 | 需人臉 embedding 模型與分群演算法；資料僅存於裝置 |

**優化小計：13.3 人週**（P0：1.3 / P1：6.5 / P2：5.5）

### 4.3 共通工作

| 項目 | 工作量 | 說明 |
|---|---|---|
| UI/UX 設計與整合 | 2 | — |
| 雙平台實機測試 | 1.5 | 個人使用，以自己的裝置為主 |
| 效能調校（記憶體、電量、索引速度） | 1 | — |
| 個人安裝部署 | 0.5 | Android 直接安裝 APK；iOS 見第 6 節風險 |
| AI 輔助開發工具建置（Graphify、GitNexus） | 0.3 | 安裝、建立索引、合併 CLAUDE.md、設定 `.gitignore` 與 git hooks |

**共通小計：5.3 人週**

> 相較 v0.1：移除上架準備（-1）與後端代理（-1），測試範圍縮小（-0.5）。

---

## 5. 開發階段規劃

| 階段 | 內容 | 工作量 | 累計 |
|---|---|---|---|
| **Phase 0：PoC** | 專案建置（含 Graphify、GitNexus）、C3 模型驗證、C1 權限、C9/C10 相簿操作技術驗證 | 2.8 週 | 2.8 週 |
| **Phase 1：MVP** | 其餘核心功能（含 C12）+ O1、O2、O3 + UI + 測試 + 個人部署 | 16.3 週 | 19.1 週 |
| **Phase 2：智慧化** | O4 ~ O9 + 效能調校 + 回歸測試 | 8 週 | 27.1 週 |
| **Phase 3：進階** | O10 ~ O12 | 5.5 週 | 32.6 週 |

> MVP 約 **4.5 個月**；完整功能約 **7.5 個月**（1 人）。
> 以上為粗估，Phase 0 結束後應依 PoC 結果重新評估。
>
> 註：v0.1 的 Phase 1 工作量有低估，本版已依各項目逐一重新加總。

---

## 6. 風險評估

| 風險 | 影響 | 機率 | 對策 |
|---|---|---|---|
| 中文提示詞準確度不足 | 高 | 中 | Phase 0 先做 PoC；備案為內建簡易中英詞彙對照，將提示詞轉成英文 |
| 規則式解析彈性有限（無 LLM） | 中 | 高 | 先涵蓋常用句型（時間、地點、類型）；未匹配部分整段交給語意搜尋 |
| 首次索引耗時（1 萬張約 10~30 分鐘，視機型） | 中 | 高 | 進度條、斷點續做、僅充電時執行選項、優先索引最近照片 |
| 模型下載失敗或檔案損毀 | 中 | 低 | 斷點續傳 + SHA-256 校驗；失敗可重試 |
| Android 搬移需系統確認框 | 中 | 必然 | 批次一次授權；UX 事先說明 |
| iOS 無真正「搬移」語意 | 低 | 必然 | 統一用詞「加入相簿」 |
| iOS 背景執行受限 | 中 | 高 | 以前景索引為主，搭配 BGProcessingTask |
| **iOS 個人安裝簽署** | 中 | 必然 | 免費 Apple ID 簽署的 App 每 7 天需重新安裝；若要長期使用，需付費 Apple Developer Program（年費）並用 TestFlight 或 Ad Hoc 安裝 |
| Android 機型碎片化（GPU delegate 相容性） | 低 | 中 | 個人使用機型固定，影響小；仍保留失敗時退回 CPU 推論 |
| iCloud 優化儲存（原檔不在本機） | 低 | 中 | 用縮圖做索引，不下載原檔 |
| AI 輔助工具的圖譜過期或解析不完整（Dart 支援仍在演進） | 低 | 中 | 設定 git hooks 自動重建；Phase 0 實測 Dart 解析品質，不佳時以一般搜尋為主 |
| 兩個工具功能重疊、CLAUDE.md 指示衝突 | 低 | 中 | 依第 2.1 節分工；建置後人工合併 CLAUDE.md |

---

## 7. 已確認事項

- [x] 目標平台：雙平台同時上線
- [x] 雲端 LLM：完全不用雲端
- [x] 人臉分群：保留在 Phase 3
- [x] 模型提供：首次啟動時下載
- [x] 照片量級：約 1 萬張以內
- [x] 商業模式：個人使用／不上架
- [x] MVP 範圍：O1、O2、O3 全部列入

---

## 8. 建議下一步

1. 建立 Flutter 專案並完成 Graphify、GitNexus 建置（第 2.1 節）
2. 執行 **Phase 0 PoC**（約 2.8 週）：用 Python 比較 2~3 個多語 CLIP 模型在自己相簿上的中文提示詞準確度
3. 同步用 Flutter 小專案驗證 Android 批次搬移與 iOS 建立相簿流程
4. 決定 iOS 簽署方式（免費 Apple ID 或付費開發者帳號）
5. 依 PoC 結果確認模型後，定案 MVP 時程
