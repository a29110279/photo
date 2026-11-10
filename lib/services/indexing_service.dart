import 'dart:typed_data';

import 'package:photo_manager/photo_manager.dart';

import '../data/local_store.dart';
import '../data/media_repository.dart';
import 'embedding_service.dart';

class IndexProgress {
  const IndexProgress({this.total = 0, this.done = 0, this.failed = 0, this.running = false});
  final int total;
  final int done;
  final int failed;
  final bool running;

  int get pending => total - done - failed;
}

/// 索引管線（C5/C7）：增量同步 → 逐批計算 embedding → 寫入資料庫。
/// 每個 asset 完成即落盤，因此中斷後可從斷點續做。
class IndexingService {
  IndexingService(this.store, this.media);

  final LocalStore store;
  final MediaRepository media;

  bool _cancel = false;
  bool _running = false;
  bool get isRunning => _running;

  void cancel() => _cancel = true;

  /// 與裝置媒體清單同步（新增／刪除／修改）。
  Future<void> sync() async => store.syncAssets(await media.allRecords());

  Future<IndexProgress> progress(String? modelVersion, {bool running = false}) async {
    final s = await store.indexStats(modelVersion);
    return IndexProgress(total: s.total, done: s.done, failed: s.failed, running: running);
  }

  /// 執行索引直到完成或被取消。[onProgress] 每處理一個 asset 回報一次。
  Future<void> run(
    EmbeddingService embedder, {
    void Function(IndexProgress)? onProgress,
  }) async {
    if (_running) return;
    _running = true;
    _cancel = false;
    try {
      await sync();
      onProgress?.call(await progress(embedder.version, running: true));
      while (!_cancel) {
        final batch = await store.pendingAssets(embedder.version);
        if (batch.isEmpty) break;
        for (final rec in batch) {
          if (_cancel) break;
          await _indexOne(rec, embedder);
          onProgress?.call(await progress(embedder.version, running: true));
        }
      }
    } finally {
      _running = false;
      onProgress?.call(await progress(embedder.version));
    }
  }

  Future<void> _indexOne(AssetRecord rec, EmbeddingService embedder) async {
    try {
      final entity = await AssetEntity.fromId(rec.id);
      if (entity == null) {
        await store.markFailed(rec.id);
        return;
      }
      final vectors = <Float32List>[];
      for (final frame in await media.framesFor(entity)) {
        final v = await embedder.embedImage(frame);
        if (v != null) vectors.add(v);
      }
      if (vectors.isEmpty) {
        await store.markFailed(rec.id);
        return;
      }
      final loc = rec.lat == null ? await media.location(entity) : null;
      await store.saveEmbeddings(rec.id, vectors, embedder.version,
          lat: loc?.$1, lng: loc?.$2);
    } on Object {
      await store.markFailed(rec.id);
    }
  }
}
