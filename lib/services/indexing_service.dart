import 'dart:typed_data';

import 'package:photo_manager/photo_manager.dart';

import '../data/local_store.dart';
import '../data/media_repository.dart';
import 'embedding_service.dart';
import 'ocr_service.dart';

class IndexProgress {
  const IndexProgress({
    this.total = 0,
    this.done = 0,
    this.failed = 0,
    this.running = false,
    this.ocrTotal = 0,
    this.ocrDone = 0,
  });
  final int total;
  final int done;
  final int failed;
  final bool running;

  /// OCR 只處理相片。
  final int ocrTotal;
  final int ocrDone;

  int get pending => total - done - failed;
  int get ocrPending => ocrTotal - ocrDone;
}

/// 索引管線（C5/C7/O9）：增量同步 → 計算 embedding →（選用）OCR → 寫入資料庫。
/// 每個 asset 完成即落盤，因此中斷後可從斷點續做。
class IndexingService {
  IndexingService(this.store, this.media, {this.ocr = const OcrService()});

  final LocalStore store;
  final MediaRepository media;
  final OcrService ocr;

  bool _cancel = false;
  bool _running = false;
  bool get isRunning => _running;

  void cancel() => _cancel = true;

  /// 與裝置媒體清單同步（新增／刪除／修改）。
  Future<void> sync() async => store.syncAssets(await media.allRecords());

  Future<IndexProgress> progress(
    String? modelVersion, {
    bool running = false,
  }) async {
    final s = await store.indexStats(modelVersion);
    final o = await store.ocrStats();
    return IndexProgress(
      total: s.total,
      done: s.done,
      failed: s.failed,
      running: running,
      ocrTotal: o.total,
      ocrDone: o.done,
    );
  }

  /// 執行索引直到完成或被取消。[embedder] 為 null 時略過語意索引；
  /// [withOcr] 為 true 時於語意索引後執行 OCR。
  Future<void> run(
    EmbeddingService? embedder, {
    bool withOcr = false,
    void Function(IndexProgress)? onProgress,
  }) async {
    if (_running) return;
    _running = true;
    _cancel = false;
    final version = embedder?.version;
    Future<void> report() async =>
        onProgress?.call(await progress(version, running: true));
    try {
      await sync();
      await report();
      if (embedder != null) {
        while (!_cancel) {
          final batch = await store.pendingAssets(embedder.version);
          if (batch.isEmpty) break;
          for (final rec in batch) {
            if (_cancel) break;
            await _indexOne(rec, embedder);
            await report();
          }
        }
      }
      if (withOcr && OcrService.supported) {
        while (!_cancel) {
          final batch = await store.pendingOcr();
          if (batch.isEmpty) break;
          for (final rec in batch) {
            if (_cancel) break;
            await _ocrOne(rec);
            await report();
          }
        }
      }
    } finally {
      _running = false;
      onProgress?.call(await progress(version));
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
      await store.saveEmbeddings(
        rec.id,
        vectors,
        embedder.version,
        lat: loc?.$1,
        lng: loc?.$2,
      );
    } on Object {
      await store.markFailed(rec.id);
    }
  }

  Future<void> _ocrOne(AssetRecord rec) async {
    try {
      final entity = await AssetEntity.fromId(rec.id);
      final file = entity == null ? null : await media.ocrImageFile(entity);
      if (file == null) {
        await store.markOcrFailed(rec.id);
        return;
      }
      try {
        await store.saveOcr(rec.id, await ocr.recognize(file.path));
      } finally {
        await file.parent.delete(recursive: true);
      }
    } on Object {
      await store.markOcrFailed(rec.id);
    }
  }
}
