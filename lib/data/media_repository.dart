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
  Future<AssetPathEntity?> _allPath({PMFilter? filter}) async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: true,
      filterOption: filter,
    );
    return paths.isEmpty ? null : paths.first;
  }

  /// 媒體庫的快速指紋：總數 + 最新修改與最新建立的項目。
  /// 與上次相同時可略過完整列舉（新增、刪除、修改都會改變指紋）。
  Future<String> signature() async {
    final byCreate = await _allPath();
    if (byCreate == null) return 'empty';
    final count = await byCreate.assetCountAsync;
    if (count == 0) return 'empty';
    final newest = await byCreate.getAssetListRange(start: 0, end: 1);
    final byUpdate = await _allPath(
      filter: FilterOptionGroup(
        orders: const [OrderOption(type: OrderOptionType.updateDate)],
      ),
    );
    final updated = byUpdate == null
        ? const <AssetEntity>[]
        : await byUpdate.getAssetListRange(start: 0, end: 1);
    String key(List<AssetEntity> l) =>
        l.isEmpty ? '-' : '${l.first.id}@${l.first.modifiedDateSecond}';
    return '$count|${key(newest)}|${key(updated)}';
  }

  Future<List<AssetEntity>> allAssets() async {
    final all = await _allPath();
    if (all == null) return const [];
    final count = await all.assetCountAsync;
    final out = <AssetEntity>[];
    // 每頁都要經過原生通道，頁數越少越快。
    const pageSize = 2000;
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

  static final _screenshotPath = RegExp(
    r'screen ?shots?|screen ?record|screencap|截圖|截屏|螢幕錄影|屏幕录制',
    caseSensitive: false,
  );

  /// iOS PHAssetMediaSubtype.photoScreenshot。
  static const _iosScreenshotSubtype = 1 << 2;

  /// 是否為截圖或螢幕錄影：Android 依所在資料夾，iOS 依媒體子類型。
  static bool isScreenshot(AssetEntity a) {
    if (Platform.isIOS) return a.subtype & _iosScreenshotSubtype != 0;
    final path = a.relativePath;
    return path != null && _screenshotPath.hasMatch(path);
  }

  static AssetRecord toRecord(AssetEntity a) {
    final hasGps = (a.latitude ?? 0) != 0 || (a.longitude ?? 0) != 0;
    return AssetRecord(
      screenshot: isScreenshot(a),
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

  /// 供人臉偵測使用的縮圖（O12）：人臉需要比語意索引更高的解析度。
  Future<Uint8List?> faceImage(AssetEntity a) =>
      a.thumbnailDataWithSize(const ThumbnailSize(720, 720), quality: 90);

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
