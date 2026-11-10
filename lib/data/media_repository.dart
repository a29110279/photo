import 'dart:io';
import 'dart:typed_data';

import 'package:photo_manager/photo_manager.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import 'local_store.dart';

/// 裝置媒體存取（iOS PhotoKit / Android MediaStore）。
class MediaRepository {
  const MediaRepository();

  static const _request = PermissionRequestOption(
    androidPermission: AndroidPermission(
      type: RequestType.common,
      mediaLocation: true,
    ),
  );

  Future<PermissionState> permissionState() =>
      PhotoManager.getPermissionState(requestOption: _request);

  Future<PermissionState> requestPermission() =>
      PhotoManager.requestPermissionExtend(requestOption: _request);

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
      out.addAll(await all.getAssetListRange(
          start: start, end: (start + pageSize).clamp(0, count)));
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
    const size = ThumbnailSize.square(448);
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
          final data = await VideoThumbnail.thumbnailData(
            video: file.path,
            imageFormat: ImageFormat.JPEG,
            maxWidth: 448,
            timeMs: i * step + (step ~/ 2),
            quality: 85,
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
