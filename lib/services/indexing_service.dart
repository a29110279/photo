import 'dart:typed_data';

import 'package:photo_manager/photo_manager.dart';

import '../data/local_store.dart';
import '../data/media_repository.dart';
import '../data/setting_keys.dart';
import 'embedding_service.dart';
import 'face_service.dart';
import 'ocr_service.dart';

class IndexProgress {
  const IndexProgress({
    this.total = 0,
    this.done = 0,
    this.failed = 0,
    this.running = false,
    this.ocrTotal = 0,
    this.ocrDone = 0,
    this.videos = 0,
    this.syncing = false,
    this.syncError,
    this.msPerItem,
    this.faceTotal = 0,
    this.faceDone = 0,
  });
  final int total;
  final int done;
  final int failed;
  final bool running;

  /// OCR 只處理相片。
  final int ocrTotal;
  final int ocrDone;

  /// 媒體庫中的影片數（相片數 = total - videos）。
  final int videos;

  /// 正在讀取裝置媒體庫。
  final bool syncing;

  /// 最近一次讀取媒體庫失敗的原因。
  final String? syncError;

  /// 本次執行平均每個項目的耗時（毫秒）；尚無資料為 null。
  final int? msPerItem;

  /// 人物分群（O12）：需偵測人臉的相片數與已處理數。
  final int faceTotal;
  final int faceDone;

  int get photos => total - videos;

  IndexProgress withSync({required bool syncing, String? error}) =>
      IndexProgress(
        total: total,
        done: done,
        failed: failed,
        running: running,
        ocrTotal: ocrTotal,
        ocrDone: ocrDone,
        videos: videos,
        syncing: syncing,
        syncError: error,
        msPerItem: msPerItem,
        faceTotal: faceTotal,
        faceDone: faceDone,
      );

  int get pending => total - done - failed;
  int get ocrPending => ocrTotal - ocrDone;
}

/// 索引停止的條件（非同步，例如檢查前景 App 是否在執行）。
typedef StopCheck = Future<bool> Function();

/// 預先處理好的項目：推論目前項目時，下一個項目已在讀取、解碼。
class _Prepared {
  const _Prepared(this.record, this.images);
  final AssetRecord record;

  /// 已前處理的畫面（相片一張，影片多張）。
  final List<PreparedImage> images;
}

/// 索引管線（C5/C7/O9/O10）：增量同步 → 語意索引（含清晰度）→ GPS →
/// 補算清晰度 →（選用）OCR。每個項目完成即落盤，中斷後可從斷點續做；
/// 前景與背景索引共用此流程。
class IndexingService {
  IndexingService(this.store, this.media, {this.ocr = const OcrService()});

  final LocalStore store;
  final MediaRepository media;
  final OcrService ocr;

  /// 進度回報的最短間隔：每張都查詢資料庫計數會拖慢索引。
  static const progressInterval = Duration(milliseconds: 500);

  bool _cancel = false;
  bool _running = false;
  bool get isRunning => _running;

  void cancel() => _cancel = true;

  /// 與裝置媒體清單同步（新增／刪除／修改）。
  /// 先比對媒體庫指紋，沒有變動就略過完整列舉（1 萬張需數秒）。
  Future<void> sync({bool force = false}) async {
    final signature = await media.signature();
    if (!force &&
        signature == await store.getSetting(SettingKeys.mediaSignature)) {
      return;
    }
    await store.syncAssets(await media.allRecords());
    await store.setSetting(SettingKeys.mediaSignature, signature);
  }

  Future<IndexProgress> progress(
    String? modelVersion, {
    bool running = false,
  }) async {
    final s = await store.indexStats(modelVersion);
    final o = await store.ocrStats();
    final f = await store.faceStats();
    return IndexProgress(
      faceTotal: f.total,
      faceDone: f.done,
      videos: await store.videoCount(),
      total: s.total,
      done: s.done,
      failed: s.failed,
      running: running,
      ocrTotal: o.total,
      ocrDone: o.done,
    );
  }

  /// 執行索引直到完成、被取消、[shouldStop] 回傳 true 或超過 [timeBudget]。
  /// [embedder] 為 null 時略過語意索引；[withOcr] 為 true 時最後執行 OCR。
  /// [photosOnly] 只處理相片（背景引擎沒有影片抽幀的原生通道）。
  /// 回傳是否全部完成（未被中斷）。
  Future<bool> run(
    EmbeddingService? embedder, {
    bool withOcr = false,
    FaceService? faces,
    bool doSync = true,
    bool photosOnly = false,
    void Function(IndexProgress)? onProgress,
    StopCheck? shouldStop,
    Duration? timeBudget,
  }) async {
    if (_running) return false;
    _running = true;
    _cancel = false;
    final deadline = timeBudget == null ? null : DateTime.now().add(timeBudget);
    final version = embedder?.version;

    Future<bool> stopped() async =>
        _cancel ||
        (deadline != null && DateTime.now().isAfter(deadline)) ||
        (shouldStop != null && await shouldStop());

    // 只在開始時查一次總數，之後以本地計數更新，並限制回報頻率。
    var base = const IndexProgress();
    var done = 0, failed = 0, ocrDone = 0, faceDone = 0;
    final clock = Stopwatch();
    var timed = 0;
    var lastReport = DateTime.fromMillisecondsSinceEpoch(0);
    void report({bool force = false}) {
      if (onProgress == null) return;
      final now = DateTime.now();
      if (!force && now.difference(lastReport) < progressInterval) return;
      lastReport = now;
      onProgress(
        IndexProgress(
          total: base.total,
          videos: base.videos,
          done: base.done + done,
          failed: base.failed + failed,
          ocrTotal: base.ocrTotal,
          ocrDone: base.ocrDone + ocrDone,
          faceTotal: base.faceTotal,
          faceDone: base.faceDone + faceDone,
          running: true,
          msPerItem: timed == 0 ? null : clock.elapsedMilliseconds ~/ timed,
        ),
      );
    }

    var completed = false;
    try {
      if (doSync) await sync();
      base = await progress(version, running: true);
      report(force: true);

      if (embedder != null) {
        // 讀縮圖、解碼、前處理都在 prepare 完成，與上一個項目的推論重疊。
        Future<_Prepared> prepare(AssetRecord r) async {
          try {
            final entity = await AssetEntity.fromId(r.id);
            final frames = entity == null
                ? const <Uint8List>[]
                : await media.framesFor(entity);
            final images = <PreparedImage>[];
            for (final f in frames) {
              final p = await embedder.prepare(f);
              if (p != null) images.add(p);
            }
            return _Prepared(r, images);
          } on Object {
            return _Prepared(r, const []);
          }
        }

        clock.start();
        while (!await stopped()) {
          final batch = await store.pendingAssets(
            embedder.version,
            photosOnly: photosOnly,
          );
          if (batch.isEmpty) break;
          var next = prepare(batch.first);
          for (var i = 0; i < batch.length; i++) {
            final current = await next;
            if (i + 1 < batch.length) next = prepare(batch[i + 1]);
            if (await _embed(current, embedder)) {
              done++;
            } else {
              failed++;
            }
            timed++;
            report();
            if (await stopped()) break;
          }
        }
        clock.stop();
      }

      // GPS 不影響語意搜尋，放在語意索引之後讀取。
      while (!await stopped()) {
        final batch = await store.pendingGps();
        if (batch.isEmpty) break;
        for (final rec in batch) {
          await _locate(rec);
          if (await stopped()) break;
        }
      }

      // 舊版資料庫升級後補算清晰度（新索引的相片在語意索引時已一併計算）。
      while (!await stopped()) {
        final batch = await store.pendingSharpness();
        if (batch.isEmpty) break;
        for (final rec in batch) {
          await _sharpness(rec, embedder);
          if (await stopped()) break;
        }
      }

      // 人物分群（O12，選用）：偵測人臉並計算特徵。
      if (faces != null) {
        while (!await stopped()) {
          final batch = await store.pendingFaces();
          if (batch.isEmpty) break;
          for (final rec in batch) {
            await _faces(rec, faces);
            faceDone++;
            report();
            if (await stopped()) break;
          }
        }
      }

      if (withOcr && OcrService.supported) {
        while (!await stopped()) {
          final batch = await store.pendingOcr();
          if (batch.isEmpty) break;
          for (final rec in batch) {
            await _ocrOne(rec);
            ocrDone++;
            report();
            if (await stopped()) break;
          }
        }
      }
      completed = !await stopped();
    } finally {
      _running = false;
      final last = await progress(version);
      onProgress?.call(
        IndexProgress(
          total: last.total,
          videos: last.videos,
          done: last.done,
          failed: last.failed,
          ocrTotal: last.ocrTotal,
          ocrDone: last.ocrDone,
          faceTotal: last.faceTotal,
          faceDone: last.faceDone,
          msPerItem: timed == 0 ? null : clock.elapsedMilliseconds ~/ timed,
        ),
      );
    }
    return completed;
  }

  Future<bool> _embed(_Prepared p, EmbeddingService embedder) async {
    try {
      final vectors = <Float32List>[];
      for (final image in p.images) {
        final v = await embedder.embedPrepared(image);
        if (v != null) vectors.add(v);
      }
      if (vectors.isEmpty) {
        await store.markFailed(p.record.id);
        return false;
      }
      await store.saveEmbeddings(
        p.record.id,
        vectors,
        embedder.version,
        sharpness: p.record.isVideo ? null : p.images.first.sharpness,
      );
      return true;
    } on Object {
      await store.markFailed(p.record.id);
      return false;
    }
  }

  static const _defaultSpec = PreprocessSpec(
    224,
    [0.5, 0.5, 0.5],
    [0.5, 0.5, 0.5],
    false,
  );

  /// 只算清晰度（不推論）。沒有模型時用 224×224 的預設前處理。
  Future<void> _sharpness(AssetRecord rec, EmbeddingService? embedder) async {
    try {
      final entity = await AssetEntity.fromId(rec.id);
      final frames = entity == null
          ? const <Uint8List>[]
          : await media.framesFor(entity);
      if (frames.isEmpty) {
        await store.saveSharpness(rec.id, null);
        return;
      }
      final p = embedder != null
          ? await embedder.prepare(frames.first)
          : await prepareImage(frames.first, _defaultSpec);
      await store.saveSharpness(rec.id, p?.sharpness);
    } on Object {
      await store.saveSharpness(rec.id, null);
    }
  }

  Future<void> _faces(AssetRecord rec, FaceService faces) async {
    try {
      final entity = await AssetEntity.fromId(rec.id);
      final image = entity == null ? null : await media.faceImage(entity);
      if (image == null) {
        await store.saveFaces(rec.id, const [], failed: true);
        return;
      }
      final found = await faces.process(image);
      await store.saveFaces(rec.id, [
        for (final f in found) (box: f.box.encode(), vec: f.vector),
      ]);
    } on Object {
      await store.saveFaces(rec.id, const [], failed: true);
    }
  }

  Future<void> _locate(AssetRecord rec) async {
    try {
      final entity = await AssetEntity.fromId(rec.id);
      final loc = entity == null ? null : await media.location(entity);
      await store.saveLocation(rec.id, loc?.$1, loc?.$2);
    } on Object {
      await store.saveLocation(rec.id, null, null);
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
