import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

import '../data/local_store.dart';
import '../data/media_repository.dart';
import '../services/album_service.dart';
import '../services/duplicate_service.dart';
import '../services/embedding_service.dart';
import '../services/indexing_service.dart';
import '../services/model_service.dart';
import '../services/search_service.dart';
import '../services/smart_album_service.dart';

abstract final class SettingKeys {
  static const threshold = 'threshold';
  static const imageThreshold = 'image_threshold';
  static const ocrEnabled = 'ocr_enabled';
}

/// 預設相關度門檻（cosine）。實際合適的值依模型而異，需以 PoC 校準。
const kDefaultThreshold = 0.20;

/// 以圖搜圖（影像對影像）的分數普遍較高，門檻另外設定。
const kDefaultImageThreshold = 0.75;

// 於 main() 以 overrides 注入。
final storeProvider = Provider<LocalStore>((_) => throw UnimplementedError());
final modelDirProvider = Provider<String>((_) => throw UnimplementedError());

final mediaRepositoryProvider = Provider((_) => const MediaRepository());
final modelServiceProvider = Provider(
  (ref) => ModelService(ref.watch(modelDirProvider)),
);
final searchServiceProvider = Provider(
  (ref) => SearchService(ref.watch(storeProvider)),
);
final albumServiceProvider = Provider(
  (ref) => AlbumService(ref.watch(storeProvider)),
);
final indexingServiceProvider = Provider(
  (ref) => IndexingService(
    ref.watch(storeProvider),
    ref.watch(mediaRepositoryProvider),
  ),
);

final duplicateServiceProvider = Provider(
  (ref) => DuplicateService(ref.watch(storeProvider)),
);
final smartAlbumServiceProvider = Provider(
  (ref) => SmartAlbumService(
    ref.watch(storeProvider),
    ref.watch(searchServiceProvider),
    ref.watch(albumServiceProvider),
  ),
);

/// 底部導覽目前的分頁（以圖搜圖時從預覽頁切回搜尋頁）。
class HomeTabController extends Notifier<int> {
  @override
  int build() => 0;
  void go(int i) => state = i;
}

final homeTabProvider = NotifierProvider<HomeTabController, int>(
  HomeTabController.new,
);

/// 以 id 取得 AssetEntity（供縮圖與預覽使用）。
final assetEntityProvider = FutureProvider.family<AssetEntity?, String>(
  (_, id) => AssetEntity.fromId(id),
);

// ---- 權限（C1） ----

class PermissionController extends AsyncNotifier<PermissionState> {
  @override
  Future<PermissionState> build() =>
      ref.read(mediaRepositoryProvider).permissionState();

  Future<void> request() async {
    state = AsyncData(
      await ref.read(mediaRepositoryProvider).requestPermission(),
    );
  }

  /// iOS 有限存取：重新挑選可存取的照片。
  Future<void> manageLimited() async {
    await PhotoManager.presentLimited();
    ref.invalidateSelf();
  }
}

final permissionProvider =
    AsyncNotifierProvider<PermissionController, PermissionState>(
      PermissionController.new,
    );

// ---- 模型（C12） ----

class ModelState {
  const ModelState({
    this.loading = false,
    this.embedder,
    this.progress,
    this.error,
  });
  final bool loading;
  final EmbeddingService? embedder;

  /// 首次啟動解出內建模型的進度 0~1；null 表示未在進行。
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

  Future<void> _loadInstalled() async {
    try {
      final installed = await ref
          .read(modelServiceProvider)
          .ensureBundled(
            rootBundle,
            onProgress: (p) => state = ModelState(loading: true, progress: p),
          );
      state = ModelState(
        embedder: installed == null
            ? null
            : await EmbeddingService.load(installed),
      );
    } on Object catch (e) {
      state = ModelState(error: '模型載入失敗：$e');
    }
  }
}

final modelProvider = NotifierProvider<ModelController, ModelState>(
  ModelController.new,
);

// ---- 索引（C5） ----

class IndexController extends Notifier<IndexProgress> {
  @override
  IndexProgress build() {
    // 啟動時先同步媒體清單，讓日期／類型篩選在索引前就能使用。
    Future.microtask(resync);
    return const IndexProgress(syncing: true);
  }

  bool _syncing = false;

  /// 重新讀取裝置媒體庫（啟動、回到前景、使用者手動觸發時）。
  Future<void> resync() async {
    if (_svc.isRunning || _syncing) return;
    _syncing = true;
    state = state.withSync(syncing: true);
    String? error;
    try {
      await _svc.sync();
    } on Object catch (e) {
      error = '$e';
    } finally {
      _syncing = false;
    }
    final version = ref.read(modelProvider).embedder?.version;
    state = (await _svc.progress(version))
        .withSync(syncing: false, error: error);
  }

  IndexingService get _svc => ref.read(indexingServiceProvider);

  Future<void> refresh() async {
    if (_svc.isRunning || _syncing) return;
    final version = ref.read(modelProvider).embedder?.version;
    state = (await _svc.progress(version))
        .withSync(syncing: false, error: state.syncError);
  }

  Future<void> start() async {
    final embedder = ref.read(modelProvider).embedder;
    final withOcr = ref.read(ocrEnabledProvider);
    if ((embedder == null && !withOcr) || _svc.isRunning) return;
    try {
      await _svc.run(embedder, withOcr: withOcr, onProgress: (p) => state = p);
    } finally {
      // 新索引的項目可能符合智慧相簿規則。
      ref.invalidate(smartAlbumPendingProvider);
    }
  }

  void stop() => _svc.cancel();

  Future<void> reset({bool onlyFailed = false}) async {
    if (_svc.isRunning) return;
    await ref.read(storeProvider).resetIndex(onlyFailed: onlyFailed);
    await refresh();
  }
}

final indexProvider = NotifierProvider<IndexController, IndexProgress>(
  IndexController.new,
);

/// OCR 開關（O9）：預設關閉，因為會增加索引時間。
class OcrSettingController extends Notifier<bool> {
  @override
  bool build() {
    Future.microtask(() async {
      state =
          await ref.read(storeProvider).getSetting(SettingKeys.ocrEnabled) ==
          '1';
    });
    return false;
  }

  Future<void> set(bool v) async {
    state = v;
    await ref
        .read(storeProvider)
        .setSetting(SettingKeys.ocrEnabled, v ? '1' : '0');
  }
}

final ocrEnabledProvider = NotifierProvider<OcrSettingController, bool>(
  OcrSettingController.new,
);

// ---- 搜尋（C6/C8/C11/O2） ----

class SearchUiState {
  const SearchUiState({
    this.result,
    this.threshold = kDefaultThreshold,
    this.imageThreshold = kDefaultImageThreshold,
    this.selected = const {},
    this.busy = false,
    this.error,
  });

  final SearchResult? result;
  final double threshold;
  final double imageThreshold;
  final Set<String> selected;
  final bool busy;
  final String? error;

  /// 目前結果適用的門檻（文字查詢與以圖搜圖分開）。
  double get activeThreshold =>
      result?.byImage == true ? imageThreshold : threshold;

  List<SearchHit> get visible => result?.above(activeThreshold) ?? const [];

  SearchUiState copyWith({
    SearchResult? result,
    double? threshold,
    double? imageThreshold,
    Set<String>? selected,
    bool? busy,
    String? error,
  }) => SearchUiState(
    result: result ?? this.result,
    threshold: threshold ?? this.threshold,
    imageThreshold: imageThreshold ?? this.imageThreshold,
    selected: selected ?? this.selected,
    busy: busy ?? this.busy,
    error: error,
  );
}

class SearchController extends Notifier<SearchUiState> {
  @override
  SearchUiState build() {
    Future.microtask(() async {
      final store = ref.read(storeProvider);
      final saved = double.tryParse(
        await store.getSetting(SettingKeys.threshold) ?? '',
      );
      final savedImage = double.tryParse(
        await store.getSetting(SettingKeys.imageThreshold) ?? '',
      );
      state = state.copyWith(threshold: saved, imageThreshold: savedImage);
    });
    return const SearchUiState();
  }

  Future<void> search(String input) async {
    if (input.trim().isEmpty) return;
    state = state.copyWith(busy: true, selected: {});
    try {
      final embedder = ref.read(modelProvider).embedder;
      final result = await ref
          .read(searchServiceProvider)
          .search(
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

  /// 以圖搜圖（O7）。
  Future<void> searchByImage(String assetId) => _run(() {
    final e = _embedder();
    return ref
        .read(searchServiceProvider)
        .searchByImage(assetId, modelVersion: e.version, dim: e.dim);
  });

  /// 回饋學習（O8）：選取的視為相關，看過但未選的視為不相關，重新排序。
  Future<void> refine() {
    final prev = state.result;
    if (prev == null || !prev.isSemantic || state.selected.isEmpty) {
      return Future.value();
    }
    final positives = {...state.selected};
    // 只把排在最後一個選取項目之前、且未選的視為「看過但不要」。
    final visible = state.visible;
    final last = visible.lastIndexWhere((h) => positives.contains(h.asset.id));
    final negatives = {
      for (final h in visible.take(last + 1))
        if (!positives.contains(h.asset.id)) h.asset.id,
    };
    return _run(() {
      final e = _embedder();
      return ref
          .read(searchServiceProvider)
          .refine(
            prev,
            positives: positives,
            negatives: negatives,
            modelVersion: e.version,
            dim: e.dim,
          );
    }, keepSelection: true);
  }

  EmbeddingService _embedder() {
    final e = ref.read(modelProvider).embedder;
    if (e == null) throw StateError('尚未下載模型');
    return e;
  }

  Future<void> _run(
    Future<SearchResult> Function() task, {
    bool keepSelection = false,
  }) async {
    state = state.copyWith(busy: true, selected: keepSelection ? null : {});
    try {
      state = state.copyWith(result: await task(), busy: false);
    } on Object catch (e) {
      state = state.copyWith(busy: false, error: '$e');
    }
  }

  void setThreshold(double v) {
    // 門檻提高後已不可見的項目一併取消選取。
    final next = state.result?.byImage == true
        ? state.copyWith(imageThreshold: v)
        : state.copyWith(threshold: v);
    final ids = {for (final h in next.visible) h.asset.id};
    state = next.copyWith(selected: state.selected.intersection(ids));
  }

  Future<void> saveThreshold() => state.result?.byImage == true
      ? ref
            .read(storeProvider)
            .setSetting(
              SettingKeys.imageThreshold,
              state.imageThreshold.toStringAsFixed(3),
            )
      : ref
            .read(storeProvider)
            .setSetting(
              SettingKeys.threshold,
              state.threshold.toStringAsFixed(3),
            );

  void toggle(String id) {
    final s = {...state.selected};
    if (!s.remove(id)) s.add(id);
    state = state.copyWith(selected: s);
  }

  void selectAll() => state = state.copyWith(
    selected: {for (final h in state.visible) h.asset.id},
  );

  void clearSelection() => state = state.copyWith(selected: {});

  /// 反選：先全選再點掉不要的（排除），或反過來。
  void invertSelection() => state = state.copyWith(
    selected: {
      for (final h in state.visible)
        if (!state.selected.contains(h.asset.id)) h.asset.id,
    },
  );

  /// 搬移／加入完成後，把已處理的項目從選取中移除。
  void afterAlbumOp() => clearSelection();
}

final searchProvider = NotifierProvider<SearchController, SearchUiState>(
  SearchController.new,
);

// ---- 相簿與操作日誌 ----

final albumsProvider = FutureProvider.autoDispose<List<AssetPathEntity>>(
  (ref) => ref.watch(albumServiceProvider).albums(),
);

final opLogProvider = FutureProvider.autoDispose<List<OpLogEntry>>(
  (ref) => ref.watch(storeProvider).opLogs(),
);

// ---- 智慧相簿（O5） ----

final smartAlbumsProvider = FutureProvider.autoDispose<List<SmartAlbum>>(
  (ref) => ref.watch(storeProvider).smartAlbums(),
);

/// 某個智慧相簿目前待加入的項目。
final smartAlbumPendingProvider = FutureProvider.autoDispose
    .family<List<String>, SmartAlbum>((ref, rule) {
      final embedder = ref.watch(modelProvider).embedder;
      return ref
          .watch(smartAlbumServiceProvider)
          .pending(
            rule,
            embedText: embedder?.embedText,
            modelVersion: embedder?.version,
            dim: embedder?.dim ?? 0,
          );
    });
