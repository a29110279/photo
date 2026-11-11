# 提示詞相簿（photo_prompt）

以自然語言提示詞（例如「去年在日本拍的海邊影片」）篩選手機內的相片與影片，並把結果整理進相簿。
Flutter（iOS / Android），個人使用。完整規劃見 [docs/project-evaluation.md](docs/project-evaluation.md)。

**全裝置端運算**：相片與搜尋內容不離開裝置，唯一的網路行為是下載模型。

## 目前實作範圍

| 項目 | 狀態 | 位置 |
|---|---|---|
| C1 權限（含 iOS 有限存取、Android 14 部分存取） | 已實作 | `lib/ui/app.dart`、`lib/data/media_repository.dart` |
| C2 媒體瀏覽與預覽 | 已實作 | `lib/ui/albums_page.dart`、`lib/ui/asset_widgets.dart` |
| C3 模型 PoC 腳本 | 已提供，**需自行執行** | `tools/poc/clip_poc.py` |
| C4 裝置端 embedding 推論（ONNX Runtime） | 已實作 | `lib/services/embedding_service.dart` |
| C5 索引管線（進度、斷點續做、增量更新） | 已實作（前景執行） | `lib/services/indexing_service.dart` |
| C6 Embedding 儲存與暴力比對 | 已實作 | `lib/data/local_store.dart`、`lib/services/vector_search.dart` |
| C7 影片抽幀索引（多幀取最高分） | 已實作 | `lib/data/media_repository.dart` |
| C8 Metadata 過濾（日期、類型、GPS） | 已實作 | `lib/data/local_store.dart` |
| C9 / C10 建立相簿＋加入（iOS）／搬移（Android 批次授權） | 已實作 | `lib/services/album_service.dart` |
| C11 多選、全選、反選 | 已實作 | `lib/ui/search_page.dart` |
| C12 模型下載（斷點續傳、SHA-256、更新） | 已實作 | `lib/services/model_service.dart` |
| O1 搬移前預覽＋操作日誌＋復原 | 已實作 | `lib/services/album_service.dart` |
| O2 相關度門檻滑桿 | 已實作 | `lib/ui/search_page.dart` |
| O3 資料不離開裝置 | 設計原則 | — |
| O4 規則式提示詞解析 | 已實作（搜尋流程必需，故提前） | `lib/services/query_parser.dart` |
| O5 智慧相簿（儲存規則，新項目一鍵加入） | 已實作 | `lib/services/smart_album_service.dart`、`lib/ui/albums_page.dart` |
| O6 重複／相似照片偵測 | 已實作 | `lib/services/duplicate_service.dart`、`lib/ui/cleanup_page.dart` |
| O7 以圖搜圖 | 已實作 | `SearchService.searchByImage`、預覽頁「找相似」 |
| O8 回饋學習（Rocchio） | 已實作 | `lib/services/vector_search.dart`、搜尋頁「依選取修正」 |
| O9 OCR 文字搜尋 | 已實作（原生通道） | `lib/services/ocr_service.dart`、`MainActivity.kt`、`AppDelegate.swift` |
| O10 ~ O12（Phase 3）、背景索引（workmanager / BGProcessingTask） | 未實作 | — |

與評估文件的差異：

- 資料庫用 `sqflite`（未用 `drift`），免去程式碼產生步驟。
- Android 批次搬移直接使用 `photo_manager` 內建的 `moveAssetsToPath`（內部即 `MediaStore.createWriteRequest`，需 Android 11+），因此不需自寫 Platform Channel。
- 地點過濾用內建離線地名表（`lib/services/gazetteer.dart`，約 50 個國家／城市的概略範圍），不呼叫平台 Geocoder，避免連網。
- O5 智慧相簿無法完全自動加入：Android 搬移每次都需要系統授權框，因此改為索引後計算「待加入」數量，由使用者一鍵套用。
- O9 OCR 不使用 `google_mlkit_text_recognition` 外掛（其 iOS 版只支援拉丁文字），改自寫原生通道：Android 用 ML Kit 中文辨識（bundled 模型，不需連網），iOS 用 Apple Vision（繁中、簡中、英文）。
- O6 刪除改為移到系統垃圾桶（Android 11+）或「最近刪除」（iOS），由系統相簿復原，不列入 App 的操作紀錄。
- 模型預設為 Chinese-CLIP（tokenizer 為 BERT WordPiece，可在 Dart 內實作）。若 PoC 結果改選其他模型，需替換 tokenizer。

## 驗證狀態

- `flutter analyze` 無問題；`flutter test` 38 個單元測試全數通過（解析器、tokenizer、向量比對、資料庫與 v1→v2 遷移、混合搜尋、以圖搜圖、Rocchio、相似分群、智慧相簿、OCR 文字比對）。
- 原生 OCR 通道（Kotlin / Swift）**尚未編譯過**：這個開發環境沒有 Android SDK 與 Xcode。
- **尚未在實機或模擬器上執行**，也尚未建置 APK / IPA（測試步驟見下方「實機測試清單」）。權限、推論、相簿搬移等與平台相關的流程需在裝置上驗證。
- `tools/` 內的 Python 腳本只做過語法檢查，尚未實際跑過模型匯出。

## 開始使用

```bash
flutter pub get
flutter test
```

### 1. 模型 PoC（C3）

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r tools/requirements.txt
python tools/poc/clip_poc.py --images <相片資料夾> --prompts tools/poc/prompts.txt
```

報告中的分數分布可用來校準預設相關度門檻（`lib/state/providers.dart` 的 `kDefaultThreshold`）。

### 2. 匯出並發佈模型

```bash
python tools/export_model.py --out dist/model --quantize
```

把 `dist/model/` 內的 `image`、`text`、`vocab`、`manifest.json` 放到同一層的公開靜態空間（例如 GitHub Releases）。
模型檔不含任何金鑰，下載也不需要金鑰。

### 3. 安裝到裝置

```bash
flutter run --release --dart-define=MODEL_MANIFEST_URL=<manifest.json 的網址>
```

也可不帶 `--dart-define`，改在 App 的「設定」頁輸入網址。之後依序：下載模型 → 開始索引 → 搜尋。

iOS 簽署方式（免費 Apple ID 每 7 天需重裝，或付費開發者帳號）見評估文件第 6 節。

### 4. AI 輔助開發工具（Graphify、GitNexus）

```bash
bash tools/dev_setup.sh
```

只影響開發環境。執行後需人工合併兩個工具寫入 `CLAUDE.md` 的指示。

## 實機測試清單

單元測試只涵蓋純 Dart 邏輯；以下需在裝置上逐項確認（`flutter run --release`）：

| # | 步驟 | 預期結果 |
|---|---|---|
| 1 | 首次開啟並授權（iOS 試「選取部分相片」） | 進入主畫面；設定頁顯示權限狀態 |
| 2 | 設定 › 下載模型 → 中途關閉網路再開啟重試 | 從中斷處續傳，完成後顯示模型版本 |
| 3 | 設定 › 開始索引 → 中途暫停、關閉 App 再開 | 再按「繼續」從斷點續做；最近的相片先完成 |
| 4 | 搜尋「去年的影片」（不需模型） | 只出現去年的影片，依時間排序 |
| 5 | 搜尋「海邊」、拖動相關度滑桿 | 分數由高到低；門檻提高結果變少 |
| 6 | 選幾張 → 搬移／加入相簿 → 按「復原」 | Android 跳一次系統授權後檔案移到 `Pictures/<名稱>/`，復原後回原資料夾；iOS 加入相簿，復原後移出 |
| 7 | 長按任一縮圖 → 右上「找相似」 | 回到搜尋頁顯示相似項目，不含自己；滑桿範圍變為 0~1 |
| 8 | 搜尋結果中只勾選想要的 → 按「依選取修正」（調整圖示） | 結果重新排序，出現「已依選取修正」標籤 |
| 9 | 搜尋後右上「存成智慧相簿」→ 拍一張新照片 → 設定 › 繼續索引 → 相簿 › 智慧相簿 | 新照片若符合條件，出現在待加入數量中；套用後不再重複提示 |
| 10 | 整理 › 掃描（拍幾張連拍） | 連拍成群，預設保留最早一張；刪除後可在系統垃圾桶／最近刪除找回 |
| 11 | 設定 › 開啟文字辨識 → 繼續索引 → 搜尋 `「發票」`（中文截圖） | 出現含該文字的相片；OCR 進度顯示在設定頁 |
| 12 | 從 v1 版本升級安裝（已有索引資料） | 不需重新索引；OCR 狀態為未處理 |

另外建議觀察：1 萬張索引的總時間與耗電、搜尋回應時間（目標 1 秒內）、相似分群在「全部比對」模式的耗時。

## 架構

```
lib/
 ├─ ui/         搜尋、相簿（含智慧相簿、操作紀錄）、整理、設定、預覽
 ├─ state/      Riverpod providers / controllers
 ├─ services/   QueryParser、SearchService、IndexingService、
 │              EmbeddingService、ModelService、AlbumService、
 │              SmartAlbumService、DuplicateService、OcrService
 └─ data/       MediaRepository（photo_manager）、LocalStore（sqflite）
```

搜尋流程：規則式解析 → metadata 過濾候選集 → 文字 embedding 與候選影像 embedding 做 cosine 比對 → 依門檻與分數排序。
