# Graph Report - photo  (2026-11-10)

## Corpus Check
- cluster-only mode — file stats not available

## Summary
- 604 nodes · 747 edges · 41 communities (33 shown, 8 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `d714b540`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- local_store.dart
- model_service.dart
- embedding_service.dart
- providers.dart
- query_parser.dart
- dependencies
- clip_poc.py
- albums_page.dart
- asset_widgets.dart
- AppDelegate
- indexing_service.dart
- search_service.dart
- search_page.dart
- album_service.dart
- settings_page.dart
- vector_search.dart
- core_test.dart
- Refactoring with GitNexus
- _SearchPageState
- bert_tokenizer.dart
- GitNexus CLI Commands
- GitNexus Guide
- IndexController
- Impact Analysis with GitNexus
- app.dart
- Debugging with GitNexus
- Exploring Codebases with GitNexus
- GitNexus — Code Intelligence
- modelProvider
- State
- GitNexus — Code Intelligence
- analysis_options.yaml
- PermissionController
- query_parser_test.dart
- MainActivity.kt
- dev_setup.sh

## God Nodes (most connected - your core abstractions)
1. `dependencies` - 15 edges
2. `modelProvider` - 11 edges
3. `Impact Analysis with GitNexus` - 9 edges
4. `Refactoring with GitNexus` - 8 edges
5. `Debugging with GitNexus` - 8 edges
6. `Exploring Codebases with GitNexus` - 8 edges
7. `_SearchPageState` - 7 edges
8. `LocalStore` - 6 edges
9. `_SettingsPageState` - 6 edges
10. `GitNexus Guide` - 6 edges

## Surprising Connections (you probably didn't know these)
- `embed_images()` --references--> `image`  [EXTRACTED]
  tools/poc/clip_poc.py → pubspec.yaml
- `_submit` --references--> `searchProvider`  [EXTRACTED]
  lib/ui/search_page.dart → lib/state/providers.dart
- `_addToAlbum` --references--> `albumServiceProvider`  [EXTRACTED]
  lib/ui/search_page.dart → lib/state/providers.dart
- `build` --references--> `modelProvider`  [EXTRACTED]
  lib/ui/search_page.dart → lib/state/providers.dart
- `_SearchPageState` --references--> `albumServiceProvider`  [EXTRACTED]
  lib/ui/search_page.dart → lib/state/providers.dart

## Import Cycles
- None detected.

## Communities (41 total, 8 thin omitted)

### Community 0 - "local_store.dart"
Cohesion: 0.04
Nodes (46): addOpLog, albumId, albumName, asset_id, assetId, assets, close, createTs (+38 more)

### Community 1 - "model_service.dart"
Cohesion: 0.04
Nodes (36): allAssets, allRecords, framesFor, _localFile, MediaRepository, permissionState, _request, requestPermission (+28 more)

### Community 2 - "embedding_service.dart"
Cohesion: 0.06
Nodes (26): centerCrop, decoded, dim, dispose, EmbeddingService, embedImage, embedText, i (+18 more)

### Community 3 - "providers.dart"
Cohesion: 0.06
Nodes (27): afterAlbumOp, busy, clearSelection, copyWith, embedder, error, invertSelection, kDefaultManifestUrl (+19 more)

### Community 4 - "query_parser.dart"
Cohesion: 0.06
Nodes (24): aliases, box, contains, GeoBox, kPlaces, maxLng, name, Place (+16 more)

### Community 5 - "dependencies"
Cohesion: 0.07
Nodes (29): dependencies, crypto, cupertino_icons, dio, flutter, flutter_riverpod, image, onnxruntime (+21 more)

### Community 6 - "clip_poc.py"
Cohesion: 0.11
Nodes (8): ImageEncoder, main(), sha256(), TextEncoder, embed_images(), embed_texts(), features(), main()

### Community 7 - "albums_page.dart"
Cohesion: 0.10
Nodes (22): OpLogEntry, albumServiceProvider, albumsProvider, assetEntityProvider, opLogProvider, album, _AlbumList, AlbumsPage (+14 more)

### Community 8 - "asset_widgets.dart"
Cohesion: 0.10
Nodes (16): assetId, badge, _controller, createState, dispose, entity, _error, formatDuration (+8 more)

### Community 9 - "AppDelegate"
Cohesion: 0.11
Nodes (6): Flutter, AppDelegate, SceneDelegate, RunnerTests, UIKit, XCTest

### Community 10 - "indexing_service.dart"
Cohesion: 0.11
Nodes (14): _cancel, done, failed, IndexingService, _indexOne, isRunning, media, pending (+6 more)

### Community 11 - "search_service.dart"
Cohesion: 0.11
Nodes (15): AssetRecord, QueryParser, above, asset, hits, isSemantic, parser, query (+7 more)

### Community 12 - "search_page.dart"
Cohesion: 0.12
Nodes (13): ParsedQuery, PhotoPromptApp, _Chip, _Banner, createState, dispose, _error, _Hint (+5 more)

### Community 13 - "album_service.dart"
Cohesion: 0.12
Nodes (14): _addDarwin, addToAlbum, AlbumResult, albums, AlbumService, androidPath, count, logId (+6 more)

### Community 14 - "settings_page.dart"
Cohesion: 0.14
Nodes (7): main, store, support, _confirmReset, createState, dispose, _url

### Community 15 - "vector_search.dart"
Cohesion: 0.13
Nodes (10): assetIds, data, dim, EmbeddingMatrix, l2Normalize, norm, rows, score (+2 more)

### Community 16 - "core_test.dart"
Cohesion: 0.14
Nodes (5): LocalStore, main, store, ts, vec

### Community 17 - "Refactoring with GitNexus"
Cohesion: 0.17
Nodes (11): Bind the repository first, Checklists, Example: Rename `validateUser` to `authenticateUser`, Extract Module, Refactoring with GitNexus, Rename Symbol, Risk Rules, Split Function/Service (+3 more)

### Community 18 - "_SearchPageState"
Cohesion: 0.21
Nodes (10): indexProvider, searchProvider, _addToAlbum, build, SearchPage, _SearchPageState, _submit, build (+2 more)

### Community 19 - "bert_tokenizer.dart"
Cohesion: 0.17
Nodes (9): _basicTokens, BertTokenizer, encode, fromVocabText, _isCjk, _isPunct, unk, vocab (+1 more)

### Community 20 - "GitNexus CLI Commands"
Cohesion: 0.18
Nodes (10): After Indexing, analyze — Build or refresh the index, clean — Delete the index, Commands, GitNexus CLI Commands, Index storage and retention, list — Show all indexed repos, status — Check index freshness (+2 more)

### Community 21 - "GitNexus Guide"
Cohesion: 0.18
Nodes (10): Always Start Here, Control & data dependence (`pdg_query`), GitNexus Guide, Graph Schema, Paginating `list_repos`, Resources Reference, Shortest path between two symbols (`trace`), Skills (+2 more)

### Community 22 - "IndexController"
Cohesion: 0.22
Nodes (10): IndexProgress, build, download, IndexController, indexingServiceProvider, _loadInstalled, ModelController, modelServiceProvider (+2 more)

### Community 23 - "Impact Analysis with GitNexus"
Cohesion: 0.20
Nodes (9): Bind the repository first, Checklist, Example: "What breaks if I change validateUser?", Impact Analysis with GitNexus, Risk Assessment, Tools, Understanding Output, When to Use (+1 more)

### Community 24 - "app.dart"
Cohesion: 0.25
Nodes (5): permissionProvider, build, createState, _index, PermissionGate

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
Cohesion: 0.29
Nodes (8): modelProvider, refresh, search, SearchController, searchServiceProvider, SearchUiState, start, initState

### Community 29 - "State"
Cohesion: 0.32
Nodes (6): AlbumDetailPage, _AlbumDetailPageState, HomeShell, _HomeShellState, _AlbumDialog, _AlbumDialogState

### Community 30 - "GitNexus — Code Intelligence"
Cohesion: 0.29
Nodes (6): Always Do, CLI, GitNexus — Code Intelligence, Never Do, Resources, 工具分工（優先於下方工具自動產生的指示）

### Community 31 - "analysis_options.yaml"
Cohesion: 0.33
Nodes (5): analyzer, exclude, include, linter, rules

### Community 32 - "PermissionController"
Cohesion: 0.40
Nodes (3): mediaRepositoryProvider, PermissionController, request

## Knowledge Gaps
- **258 isolated node(s):** `addOpLog`, `albumId`, `albumName`, `asset_id`, `assetId` (+253 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 426 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **8 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `LocalStore` connect `core_test.dart` to `local_store.dart`, `providers.dart`, `indexing_service.dart`, `search_service.dart`, `album_service.dart`?**
  _High betweenness centrality (0.044) - this node is a cross-community bridge._
- **What connects `addOpLog`, `albumId`, `albumName` to the rest of the system?**
  _258 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `local_store.dart` be split into smaller, more focused modules?**
  _Cohesion score 0.0392156862745098 - nodes in this community are weakly interconnected._
- **Why does `BertTokenizer` connect `bert_tokenizer.dart` to `embedding_service.dart`?**
  _High betweenness centrality (0.011) - this node is a cross-community bridge._
- **Should `model_service.dart` be split into smaller, more focused modules?**
  _Cohesion score 0.0425531914893617 - nodes in this community are weakly interconnected._
- **Why does `EmbeddingService` connect `embedding_service.dart` to `providers.dart`?**
  _High betweenness centrality (0.010) - this node is a cross-community bridge._
- **Should `embedding_service.dart` be split into smaller, more focused modules?**
  _Cohesion score 0.05714285714285714 - nodes in this community are weakly interconnected._