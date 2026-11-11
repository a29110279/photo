import 'dart:io';
import 'dart:typed_data';

import 'package:photo_manager/photo_manager.dart';

import 'local_store.dart';
import 'video_frames.dart';

/// 裝置媒體存取（iOS PhotoKit / Android MediaStore）。
class MediaRepository {
  const MediaRepository();

  static const request = PermissionRequestOption(
    androidPermission: AndroidPermission(
      type: RequestType.common,
      mediaLocation: true,
    ),
  );

  Future<PermissionState> permissionState() =>
      PhotoManager.getPermissionState(requestOption: request);

  Future<PermissionState> requestPermission() =>
      PhotoManager.requestPermissionExtend(requestOption: request);

  /// 取得全部相片與影片（新到舊），以分頁讀取避免一次占用過多記憶體。
  Future<List<AssetEntity>> allAssets() async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: true,
    );
    if (paths.isEmpty) return const [];
    final all = paths.first;
    final count = await all.assetCountAsync;
    final out = <AssetEntity>[];
    const pageSize = 500;
    for (var start = 0; start < count; start += pageSize) {
      out.addAll(
        await all.getAssetListRange(
          start: start,
          end: (start + pageSize).clamp(0, count),
        ),
      );
    }
    return out;
  }

  Future<List<AssetRecord>> allRecords() async => [
    for (final a in await allAssets()) toRecord(a),
  ];

  static AssetRecord toRecord(AssetEntity a) {
    final hasGps = (a.latitude ?? 0) != 0 || (a.longitude ?? 0) != 0;
    return AssetRecord(
      id: a.id,
      isVideo: a.type == AssetType.video,
      createTs: a.createDateSecond ?? 0,
      modifiedTs: a.modifiedDateSecond ?? 0,
      duration: a.duration,
      lat: hasGps ? a.latitude : null,
      lng: hasGps ? a.longitude : null,
    );
  }

  /// 讀取 GPS（Android 需由 EXIF 取得，較慢，因此只在索引時呼叫）。
  Future<(double, double)?> location(AssetEntity a) async {
    try {
      final ll = await a.latlngAsync();
      final lat = ll?.latitude ?? 0, lng = ll?.longitude ?? 0;
      if (lat == 0 && lng == 0) return null;
      return (lat, lng);
    } on Object {
      return null;
    }
  }

  /// 供模型使用的影像資料：相片取縮圖（不下載 iCloud 原檔）；
  /// 影片每 [everySeconds] 秒抽一幀，最多 [maxFrames] 幀。
  Future<List<Uint8List>> framesFor(
    AssetEntity a, {
    int everySeconds = 5,
    int maxFrames = 8,
  }) async {
    // 模型輸入為 224×224，取稍大的縮圖即可，讀取與解碼都較快。
    const size = ThumbnailSize.square(320);
    if (a.type != AssetType.video) {
      final t = await a.thumbnailDataWithSize(size, quality: 90);
      return [?t];
    }
    final frames = <Uint8List>[];
    final file = await _localFile(a);
    if (file != null) {
      final total = a.duration;
      final count = (total ~/ everySeconds + 1).clamp(1, maxFrames);
      final step = total <= 0 ? 0 : (total * 1000) ~/ count;
      for (var i = 0; i < count; i++) {
        try {
          final data = await const VideoFrames().frameAt(
            file.path,
            i * step + (step ~/ 2),
          );
          if (data != null) frames.add(data);
        } on Object {
          // 個別幀失敗不影響其他幀。
        }
      }
    }
    if (frames.isEmpty) {
      final t = await a.thumbnailDataWithSize(size, quality: 90);
      if (t != null) frames.add(t);
    }
    return frames;
  }

  /// 供 OCR 使用的較大縮圖，寫入暫存檔；呼叫端負責刪除。
  Future<File?> ocrImageFile(AssetEntity a) async {
    final data = await a.thumbnailDataWithSize(
      const ThumbnailSize(1600, 1600),
      quality: 90,
    );
    if (data == null) return null;
    final dir = await Directory.systemTemp.createTemp('ocr');
    return File('${dir.path}/image.jpg').writeAsBytes(data);
  }

  /// 移到系統垃圾桶（Android 11+）或「最近刪除」（iOS），皆可由系統相簿復原。
  /// 系統會跳出確認框。回傳實際刪除的 id。
  Future<List<String>> trash(List<String> ids) async {
    if (Platform.isAndroid) {
      final sdk =
          int.tryParse(
            RegExp(r'\d+').firstMatch(await PhotoManager.systemVersion())?[0] ??
                '',
          ) ??
          0;
      if (sdk >= 30) {
        final entities = <AssetEntity>[];
        for (final id in ids) {
          final e = await AssetEntity.fromId(id);
          if (e != null) entities.add(e);
        }
        return PhotoManager.editor.android.moveToTrash(entities);
      }
    }
    return PhotoManager.editor.deleteWithIds(ids);
  }

  Future<File?> _localFile(AssetEntity a) async {
    try {
      // 原檔不在本機（iCloud 優化儲存）時不強制下載，改用縮圖。
      if (!await a.isLocallyAvailable()) return null;
      return await a.file;
    } on Object {
      return null;
    }
  }
}
