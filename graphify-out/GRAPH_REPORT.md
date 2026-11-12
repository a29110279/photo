# Graph Report - photo  (2026-11-12)

## Corpus Check
- 67 files · ~37,661 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 38 file(s) not represented in the graph (top: .xml 10, (none) 9, .plist 4)
- WARNING: 38 of 150 files seen (25%) have no supported extractor and are missing from this graph entirely. It may look complete while representing only part of the codebase.

## Summary
- 1199 nodes · 1545 edges · 63 communities (50 shown, 13 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS · INFERRED: 2 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `c8d8194e`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- local_store.dart
- model_service.dart
- embedding_service.dart
- providers.dart
- query_parser.dart
- dependencies
- export_model.py
- albums_page.dart
- asset_widgets.dart
- AppDelegate
- indexing_service.dart
- search_service.dart
- search_page.dart
- album_service.dart
- app.dart
- vector_search.dart
- sync_cleanup_test.dart
- Refactoring with GitNexus
- indexProvider
- model_service_test.dart
- GitNexus CLI Commands
- GitNexus Guide
- storeProvider
- Impact Analysis with GitNexus
- face_service.dart
- Debugging with GitNexus
- Exploring Codebases with GitNexus
- GitNexus — Code Intelligence
- modelProvider
- homeTabProvider
- GitNexus — Code Intelligence
- analysis_options.yaml
- PermissionController
- with
- MainActivity.kt
- dev_setup.sh
- background_indexing.dart
- event_service.dart
- with
- NativeMediaPlugin.kt
- theme.dart
- cleanup_page.dart
- media_repository.dart
- steps
- native_media/pubspec.yaml
- people_service.dart
- static const
- smart_album_service.dart
- List
- setting_keys.dart
- ../data/local_store.dart
- dart:io
- native_media/analysis_options.yaml
- PackageDescription

## God Nodes (most connected - your core abstractions)
1. `modelProvider` - 17 edges
2. `storeProvider` - 14 edges
3. `dependencies` - 13 edges
4. `LocalStore` - 12 edges
5. `searchProvider` - 10 edges
6. `NativeMediaPlugin` - 10 edges
7. `with` - 9 edges
8. `Impact Analysis with GitNexus` - 9 edges
9. `with` - 8 edges
10. `IndexController` - 8 edges

## Surprising Connections (you probably didn't know these)
- `FakeMedia` --inherits--> `MediaRepository`  [EXTRACTED]
  test/sync_cleanup_test.dart → lib/data/media_repository.dart
- `IndexController` --references--> `IndexProgress`  [EXTRACTED]
  lib/state/providers.dart → lib/services/indexing_service.dart
- `_deleteRule` --references--> `storeProvider`  [EXTRACTED]
  lib/ui/albums_page.dart → lib/state/providers.dart
- `_SmartAlbumPageState` --references--> `storeProvider`  [EXTRACTED]
  lib/ui/albums_page.dart → lib/state/providers.dart
- `_HomeShellState` --references--> `storeProvider`  [EXTRACTED]
  lib/ui/app.dart → lib/state/providers.dart

## Import Cycles
- None detected.

## Communities (63 total, 13 thin omitted)

### Community 0 - "local_store.dart"
Cohesion: 0.02
Nodes (88): addOpLog, album_id, albumId, albumName, allAssets, allFaces, asset_id, assetId (+80 more)

### Community 1 - "model_service.dart"
Cohesion: 0.07
Nodes (26): centerCrop, contextLength, dir, embeddingDim, ensureBundled, fileKeys, files, fromJson (+18 more)

### Community 2 - "embedding_service.dart"
Cohesion: 0.05
Nodes (38): centerCrop, codec, d0, dim, dispose, embedImage, embedPrepared, embedText (+30 more)

### Community 3 - "providers.dart"
Cohesion: 0.04
Nodes (46): activeThreshold, afterAlbumOp, albumsProvider, assets, blurriestProvider, busy, clear, clearSelection (+38 more)

### Community 4 - "query_parser.dart"
Cohesion: 0.07
Nodes (23): _cleanSemantic, dateLabel, _digits, from, hasFilter, kind, MediaKind, months (+15 more)

### Community 5 - "dependencies"
Cohesion: 0.07
Nodes (29): dependencies, cupertino_icons, flutter, flutter_riverpod, native_media, onnxruntime, path, path_provider (+21 more)

### Community 6 - "export_model.py"
Cohesion: 0.07
Nodes (19): main(), min_cos(), samples(), sha256(), ImageEncoder, main(), _quant_candidates(), quantize_dynamic() (+11 more)

### Community 7 - "albums_page.dart"
Cohesion: 0.07
Nodes (27): OpLogEntry, SmartAlbum, album, _AlbumList, AlbumsPage, _apply, _busy, _createAlbum (+19 more)

### Community 8 - "asset_widgets.dart"
Cohesion: 0.07
Nodes (24): assetEntityProvider, AlbumDetailPage, _AlbumDetailPageState, assetId, AssetTile, badge, build, _controller (+16 more)

### Community 9 - "AppDelegate"
Cohesion: 0.07
Nodes (10): AVFoundation, Flutter, AppDelegate, SceneDelegate, RunnerTests, NativeMediaPlugin, UIKit, Vision (+2 more)

### Community 10 - "indexing_service.dart"
Cohesion: 0.05
Nodes (36): _cancel, _defaultSpec, done, _embed, faceDone, _faces, faceTotal, failed (+28 more)

### Community 11 - "search_service.dart"
Cohesion: 0.09
Nodes (20): AssetRecord, QueryParser, above, asset, byImage, hits, isSemantic, parser (+12 more)

### Community 12 - "search_page.dart"
Cohesion: 0.10
Nodes (19): SearchResult, albumServiceProvider, searchProvider, _OpLogTile, _addToAlbum, createState, _delete, dispose (+11 more)

### Community 13 - "album_service.dart"
Cohesion: 0.12
Nodes (15): _addDarwin, addToAlbum, AlbumResult, albums, AlreadyInAlbumException, androidPath, count, logId (+7 more)

### Community 14 - "app.dart"
Cohesion: 0.11
Nodes (7): main, store, createState, dispose, _heartbeat, _lifecycle, _startHeartbeat

### Community 15 - "vector_search.dart"
Cohesion: 0.06
Nodes (28): alpha, append, assetIds, beta, _data, dim, EmbeddingMatrix, find (+20 more)

### Community 16 - "sync_cleanup_test.dart"
Cohesion: 0.06
Nodes (31): LocalStore, main, store, ts, vec, a, burst, main (+23 more)

### Community 17 - "Refactoring with GitNexus"
Cohesion: 0.17
Nodes (11): Bind the repository first, Checklists, Example: Rename `validateUser` to `authenticateUser`, Extract Module, Refactoring with GitNexus, Rename Symbol, Risk Rules, Split Function/Service (+3 more)

### Community 18 - "indexProvider"
Cohesion: 0.24
Nodes (11): facesEnabledProvider, indexProvider, ocrEnabledProvider, permissionProvider, _PeopleList, build, initState, PermissionGate (+3 more)

### Community 19 - "model_service_test.dart"
Cohesion: 0.08
Nodes (18): _basicTokens, BertTokenizer, encode, fromVocabText, _isCjk, _isPunct, unk, vocab (+10 more)

### Community 20 - "GitNexus CLI Commands"
Cohesion: 0.18
Nodes (10): After Indexing, analyze — Build or refresh the index, clean — Delete the index, Commands, GitNexus CLI Commands, Index storage and retention, list — Show all indexed repos, status — Check index freshness (+2 more)

### Community 21 - "GitNexus Guide"
Cohesion: 0.18
Nodes (10): Always Start Here, Control & data dependence (`pdg_query`), GitNexus Guide, Graph Schema, Paginating `list_repos`, Resources Reference, Shortest path between two symbols (`trace`), Skills (+2 more)

### Community 22 - "storeProvider"
Cohesion: 0.18
Nodes (12): build, FaceSettingController, HomeTabController, ModelController, ModelState, OcrSettingController, SearchController, SearchUiState (+4 more)

### Community 23 - "Impact Analysis with GitNexus"
Cohesion: 0.20
Nodes (9): Bind the repository first, Checklist, Example: "What breaks if I change validateUser?", Impact Analysis with GitNexus, Risk Assessment, Tools, Understanding Output, When to Use (+1 more)

### Community 24 - "face_service.dart"
Cohesion: 0.05
Nodes (35): _asset, box, centroids, _channel, clusterFaces, cropFace, cx, cy (+27 more)

### Community 25 - "Debugging with GitNexus"
Cohesion: 0.22
Nodes (8): Bind the repository first, Checklist, Debugging Patterns, Debugging with GitNexus, Example: "Payment endpoint returns 500 intermittently", Tools, When to Use, Workflow

### Community 26 - "Exploring Codebases with GitNexus"
Cohesion: 0.22
Nodes (8): Bind the repository first, Checklist, Example: "How does payment processing work?", Exploring Codebases with GitNexus, Resources, Tools, When to Use, Workflow

### Community 27 - "GitNexus — Code Intelligence"
Cohesion: 0.25
Nodes (7): Always Do, CLI, GitNexus — Code Intelligence, graphify, Never Do, Resources, 工具分工（優先於下方工具自動產生的指示）

### Community 28 - "modelProvider"
Cohesion: 0.18
Nodes (13): IndexProgress, autoIndex, embedder, faceServiceProvider, IndexController, indexingServiceProvider, modelProvider, peopleServiceProvider (+5 more)

### Community 29 - "homeTabProvider"
Cohesion: 0.19
Nodes (11): homeTabProvider, smartAlbumPendingProvider, build, PersonPage, SmartAlbumPage, _SmartAlbumPageState, _SmartAlbumTile, HomeShell (+3 more)

### Community 30 - "GitNexus — Code Intelligence"
Cohesion: 0.29
Nodes (6): Always Do, CLI, GitNexus — Code Intelligence, Never Do, Resources, 工具分工（優先於下方工具自動產生的指示）

### Community 31 - "analysis_options.yaml"
Cohesion: 0.33
Nodes (5): analyzer, exclude, include, linter, rules

### Community 32 - "PermissionController"
Cohesion: 0.33
Nodes (4): mediaRepositoryProvider, PermissionController, request, confirmAndTrash

### Community 33 - "with"
Cohesion: 0.05
Nodes (36): if, runs-on, steps, timeout-minutes, GH_TOKEN, KEY_ALIAS, KEY_PASSWORD, KEYSTORE_BASE64 (+28 more)

### Community 41 - "background_indexing.dart"
Cohesion: 0.06
Nodes (21): backgroundDispatcher, _budget, databasePath, embedder, faces, _foreground, _foregroundActive, hb (+13 more)

### Community 42 - "event_service.dart"
Cohesion: 0.07
Nodes (24): a, assetIds, clusterEvents, counts, distanceKm, dLat, _dominantPlace, end (+16 more)

### Community 43 - "with"
Cohesion: 0.07
Nodes (27): CASES_PATH, VOCAB_PATH, runs-on, steps, timeout-minutes, jobs, export, name (+19 more)

### Community 45 - "theme.dart"
Cohesion: 0.09
Nodes (20): PhotoPromptApp, _Chip, CleanupPage, _GroupRow, _EmptyResult, _Hint, _QueryChips, _accent (+12 more)

### Community 46 - "cleanup_page.dart"
Cohesion: 0.09
Nodes (18): build, _busy, createState, emptyText, _gone, _groups, hint, ids (+10 more)

### Community 47 - "media_repository.dart"
Cohesion: 0.09
Nodes (18): allAssets, _allPath, allRecords, faceImage, framesFor, _iosScreenshotSubtype, isScreenshot, _localFile (+10 more)

### Community 48 - "steps"
Cohesion: 0.11
Nodes (18): runs-on, steps, timeout-minutes, jobs, export, name, on, workflow_dispatch (+10 more)

### Community 49 - "native_media/pubspec.yaml"
Cohesion: 0.11
Nodes (18): package, pluginClass, dependencies, flutter, description, environment, flutter, sdk (+10 more)

### Community 50 - "people_service.dart"
Cohesion: 0.12
Nodes (12): anchors, assetIds, cover, faceIds, key, name, people, PeopleService (+4 more)

### Community 51 - "static const"
Cohesion: 0.17
Nodes (7): _channel, frameAt, VideoFrames, _channel, OcrService, recognize, supported

### Community 52 - "smart_album_service.dart"
Cohesion: 0.18
Nodes (8): AlbumService, SearchService, albums, apply, pending, search, SmartAlbumService, store

### Community 53 - "List"
Cohesion: 0.18
Nodes (8): aliases, box, contains, GeoBox, kPlaces, maxLng, name, Place

### Community 54 - "setting_keys.dart"
Cohesion: 0.22
Nodes (8): faceClusterStamp, facesEnabled, foregroundHeartbeat, imageThreshold, mediaSignature, ocrEnabled, SettingKeys, threshold

### Community 55 - "../data/local_store.dart"
Cohesion: 0.25
Nodes (3): DuplicateService, findGroups, store

### Community 56 - "dart:io"
Cohesion: 0.29
Nodes (3): casesPath, main, vocabPath

### Community 57 - "native_media/analysis_options.yaml"
Cohesion: 0.50
Nodes (3): analyzer, exclude, include

## Knowledge Gaps
- **575 isolated node(s):** `XCTest`, `workmanager_apple`, `kIndexTask`, `_periodicName`, `_oneOffName` (+570 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 854 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **13 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `LocalStore` connect `sync_cleanup_test.dart` to `local_store.dart`, `providers.dart`, `indexing_service.dart`, `search_service.dart`, `album_service.dart`, `people_service.dart`, `smart_album_service.dart`, `../data/local_store.dart`?**
  _High betweenness centrality (0.038) - this node is a cross-community bridge._
- **What connects `XCTest`, `workmanager_apple`, `kIndexTask` to the rest of the system?**
  _575 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `local_store.dart` be split into smaller, more focused modules?**
  _Cohesion score 0.020833333333333332 - nodes in this community are weakly interconnected._
- **Why does `BertTokenizer` connect `model_service_test.dart` to `embedding_service.dart`?**
  _High betweenness centrality (0.009) - this node is a cross-community bridge._
- **Should `model_service.dart` be split into smaller, more focused modules?**
  _Cohesion score 0.06666666666666667 - nodes in this community are weakly interconnected._
- **Why does `AssetRecord` connect `search_service.dart` to `local_store.dart`, `event_service.dart`, `indexing_service.dart`?**
  _High betweenness centrality (0.006) - this node is a cross-community bridge._
- **Should `embedding_service.dart` be split into smaller, more focused modules?**
  _Cohesion score 0.047619047619047616 - nodes in this community are weakly interconnected._