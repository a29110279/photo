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
| O5 ~ O12、背景索引（workmanager / BGProcessingTask） | 未實作 | — |

與評估文件的差異：

- 資料庫用 `sqflite`（未用 `drift`），免去程式碼產生步驟。
- Android 批次搬移直接使用 `photo_manager` 內建的 `moveAssetsToPath`（內部即 `MediaStore.createWriteRequest`，需 Android 11+），因此不需自寫 Platform Channel。
- 地點過濾用內建離線地名表（`lib/services/gazetteer.dart`，約 50 個國家／城市的概略範圍），不呼叫平台 Geocoder，避免連網。
- 模型預設為 Chinese-CLIP（tokenizer 為 BERT WordPiece，可在 Dart 內實作）。若 PoC 結果改選其他模型，需替換 tokenizer。

## 驗證狀態

- `flutter analyze` 無問題；`flutter test` 單元測試全數通過（解析器、tokenizer、向量比對、資料庫、混合搜尋）。
- **尚未在實機或模擬器上執行**，也尚未建置 APK / IPA。權限、推論、相簿搬移等與平台相關的流程需在裝置上驗證。
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

## 架構

```
lib/
 ├─ ui/         搜尋、相簿、設定、預覽
 ├─ state/      Riverpod providers / controllers
 ├─ services/   QueryParser、SearchService、IndexingService、
 │              EmbeddingService、ModelService、AlbumService
 └─ data/       MediaRepository（photo_manager）、LocalStore（sqflite）
```

搜尋流程：規則式解析 → metadata 過濾候選集 → 文字 embedding 與候選影像 embedding 做 cosine 比對 → 依門檻與分數排序。
