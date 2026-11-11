import 'package:flutter/services.dart';

/// 影片抽幀（C7）。透過原生通道：
/// - Android：MediaMetadataRetriever
/// - iOS：AVAssetImageGenerator
class VideoFrames {
  const VideoFrames();

  static const _channel = MethodChannel('photo_prompt/media');

  /// 取出 [timeMs] 附近的畫面，長邊縮到 [maxSize]，回傳 JPEG；失敗回傳 null。
  Future<Uint8List?> frameAt(String path, int timeMs, {int maxSize = 320}) =>
      _channel.invokeMethod<Uint8List>('videoFrame', {
        'path': path,
        'timeMs': timeMs,
        'maxSize': maxSize,
      });
}
