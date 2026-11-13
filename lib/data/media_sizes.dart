import 'package:flutter/services.dart';

/// 媒體檔案大小（整理頁的「佔空間」）。透過原生通道一次查出，
/// 不必逐一打開檔案；目前只有 Android（查 MediaStore）支援。
class MediaSizes {
  const MediaSizes();

  static const _channel = MethodChannel('photo_prompt/media');

  /// 最佔空間的 [limit] 個相片與影片：id → 位元組，由大到小。
  /// 此平台不支援或查詢失敗時回傳空的 Map。
  Future<Map<String, int>> largest({int limit = 300}) async {
    try {
      final rows = await _channel.invokeListMethod<List<Object?>>(
        'largestMedia',
        {'limit': limit},
      );
      return {
        for (final r in rows ?? const <List<Object?>>[])
          if (r.length == 2 && r[0] is String && r[1] is int)
            r[0]! as String: r[1]! as int,
      };
    } on MissingPluginException {
      return const {};
    } on PlatformException {
      return const {};
    }
  }
}

/// 位元組 → 易讀的大小（1024 進位）。
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v.toStringAsFixed(u == 0 || v >= 100 ? 0 : 1)} ${units[u]}';
}
