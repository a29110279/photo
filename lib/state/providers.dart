import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

import '../data/local_store.dart';
import '../data/media_repository.dart';
import '../services/album_service.dart';
import '../services/embedding_service.dart';
import '../services/indexing_service.dart';
import '../services/model_service.dart';
import '../services/search_service.dart';

/// 建置時可用 `--dart-define=MODEL_MANIFEST_URL=<url>` 指定預設模型清單位置。
const kDefaultManifestUrl = String.fromEnvironment('MODEL_MANIFEST_URL');

abstract final class SettingKeys {
  static const manifestUrl = 'manifest_url';
  static const threshold = 'threshold';
}

/// 預設相關度門檻（cosine）。實際合適的值依模型而異，需以 PoC 校準。
const kDefaultThreshold = 0.20;

// 於 main() 以 overrides 注入。
final storeProvider = Provider<LocalStore>((_) => throw UnimplementedError());
final modelDirProvider = Provider<String>((_) => throw UnimplementedError());

final mediaRepositoryProvider = Provider((_) => const MediaRepository());
final modelServiceProvider =
    Provider((ref) => ModelService(ref.watch(modelDirProvider)));
final searchServiceProvider =
    Provider((ref) => SearchService(ref.watch(storeProvider)));
final albumServiceProvider =
    Provider((ref) => AlbumService(ref.watch(storeProvider)));
final indexingServiceProvider = Provider((ref) => IndexingService(
    ref.watch(storeProvider), ref.watch(mediaRepositoryProvider)));

/// 以 id 取得 AssetEntity（供縮圖與預覽使用）。
final assetEntityProvider =
    FutureProvider.family<AssetEntity?, String>((_, id) => AssetEntity.fromId(id));

// ---- 權限（C1） ----

class PermissionController extends AsyncNotifier<PermissionState> {
  @override
  Future<PermissionState> build() =>
      ref.read(mediaRepositoryProvider).permissionState();

  Future<void> request() async {
    state = AsyncData(await ref.read(mediaRepositoryProvider).requestPermission());
  }

  /// iOS 有限存取：重新挑選可存取的照片。
  Future<void> manageLimited() async {
    await PhotoManager.presentLimited();
    ref.invalidateSelf();
  }
}

final permissionProvider =
    AsyncNotifierProvider<PermissionController, PermissionState>(
        PermissionController.new);

// ---- 模型（C12） ----

class ModelState {
  const ModelState({this.loading = false, this.embedder, this.progress, this.error});
  final bool loading;
  final EmbeddingService? embedder;

  /// 下載進度 0~1；null 表示未在下載。
  final double? progress;
  final String? error;

  bool get ready => embedder != null;
}

class ModelController extends Notifier<ModelState> {
  @override
  ModelState build() {
    Future.microtask(_loadInstalled);
    return const ModelState(loading: true);
  }

  Future<String> manifestUrl() async =>
      await ref.read(storeProvider).getSetting(SettingKeys.manifestUrl) ??
      kDefaultManifestUrl;

  Future<void> _loadInstalled() async {
    try {
      final installed = await ref.read(modelServiceProvider).installed();
      state = ModelState(
        embedder: installed == null ? null : await EmbeddingService.load(installed),
      );
    } on Object catch (e) {
      state = ModelState(error: '模型載入失敗：$e');
    }
  }

  Future<void> download(String url) async {
    if (state.progress != null) return;
    final old = state.embedder;
    await ref.read(storeProvider).setSetting(SettingKeys.manifestUrl, url);
    state = ModelState(embedder: old, progress: 0);
    try {
      final installed = await ref.read(modelServiceProvider).install(
            url,
            onProgress: (p) => state = ModelState(embedder: old, progress: p),
          );
      final embedder = await EmbeddingService.load(installed);
      old?.dispose();
      state = ModelState(embedder: embedder);
    } on Object catch (e) {
      state = ModelState(embedder: old, error: '下載失敗：$e');
    }
  }
}

final modelProvider =
    NotifierProvider<ModelController, ModelState>(ModelController.new);

// ---- 索引（C5） ----

class IndexController extends Notifier<IndexProgress> {
  @override
  IndexProgress build() {
    // 啟動時先同步媒體清單，讓日期／類型篩選在索引前就能使用。
    Future.microtask(() async {
      try {
        if (!_svc.isRunning) await _svc.sync();
      } on Object {
        // 尚未授權等情況：略過，之後開始索引時會再同步。
      }
      await refresh();
    });
    return const IndexProgress();
  }

  IndexingService get _svc => ref.read(indexingServiceProvider);

  Future<void> refresh() async {
    if (_svc.isRunning) return;
    final version = ref.read(modelProvider).embedder?.version;
    state = await _svc.progress(version);
  }

  Future<void> start() async {
    final embedder = ref.read(modelProvider).embedder;
    if (embedder == null || _svc.isRunning) return;
    await _svc.run(embedder, onProgress: (p) => state = p);
  }

  void stop() => _svc.cancel();

  Future<void> reset({bool onlyFailed = false}) async {
    if (_svc.isRunning) return;
    await ref.read(storeProvider).resetIndex(onlyFailed: onlyFailed);
    await refresh();
  }
}

final indexProvider =
    NotifierProvider<IndexController, IndexProgress>(IndexController.new);

// ---- 搜尋（C6/C8/C11/O2） ----

class SearchUiState {
  const SearchUiState({
    this.result,
    this.threshold = kDefaultThreshold,
    this.selected = const {},
    this.busy = false,
    this.error,
  });

  final SearchResult? result;
  final double threshold;
  final Set<String> selected;
  final bool busy;
  final String? error;

  List<SearchHit> get visible => result?.above(threshold) ?? const [];

  SearchUiState copyWith({
    SearchResult? result,
    double? threshold,
    Set<String>? selected,
    bool? busy,
    String? error,
  }) =>
      SearchUiState(
        result: result ?? this.result,
        threshold: threshold ?? this.threshold,
        selected: selected ?? this.selected,
        busy: busy ?? this.busy,
        error: error,
      );
}

class SearchController extends Notifier<SearchUiState> {
  @override
  SearchUiState build() {
    Future.microtask(() async {
      final saved = double.tryParse(
          await ref.read(storeProvider).getSetting(SettingKeys.threshold) ?? '');
      if (saved != null) state = state.copyWith(threshold: saved);
    });
    return const SearchUiState();
  }

  Future<void> search(String input) async {
    if (input.trim().isEmpty) return;
    state = state.copyWith(busy: true, selected: {});
    try {
      final embedder = ref.read(modelProvider).embedder;
      final result = await ref.read(searchServiceProvider).search(
            input,
            embedText: embedder?.embedText,
            modelVersion: embedder?.version,
            dim: embedder?.dim ?? 0,
          );
      state = state.copyWith(result: result, busy: false);
    } on Object catch (e) {
      state = state.copyWith(busy: false, error: '搜尋失敗：$e');
    }
  }

  void setThreshold(double v) {
    // 門檻提高後已不可見的項目一併取消選取。
    final next = state.copyWith(threshold: v);
    final ids = {for (final h in next.visible) h.asset.id};
    state = next.copyWith(selected: state.selected.intersection(ids));
  }

  Future<void> saveThreshold() => ref
      .read(storeProvider)
      .setSetting(SettingKeys.threshold, state.threshold.toStringAsFixed(3));

  void toggle(String id) {
    final s = {...state.selected};
    if (!s.remove(id)) s.add(id);
    state = state.copyWith(selected: s);
  }

  void selectAll() => state =
      state.copyWith(selected: {for (final h in state.visible) h.asset.id});

  void clearSelection() => state = state.copyWith(selected: {});

  /// 反選：先全選再點掉不要的（排除），或反過來。
  void invertSelection() => state = state.copyWith(selected: {
        for (final h in state.visible)
          if (!state.selected.contains(h.asset.id)) h.asset.id,
      });

  /// 搬移／加入完成後，把已處理的項目從選取中移除。
  void afterAlbumOp() => clearSelection();
}

final searchProvider =
    NotifierProvider<SearchController, SearchUiState>(SearchController.new);

// ---- 相簿與操作日誌 ----

final albumsProvider = FutureProvider.autoDispose<List<AssetPathEntity>>(
    (ref) => ref.watch(albumServiceProvider).albums());

final opLogProvider = FutureProvider.autoDispose<List<OpLogEntry>>(
    (ref) => ref.watch(storeProvider).opLogs());
