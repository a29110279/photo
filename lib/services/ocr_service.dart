import 'dart:io';

import 'package:flutter/services.dart';

/// 裝置端文字辨識（O9）。透過原生通道：
/// - Android：ML Kit 中文辨識（模型隨 App 打包，不需連網）
/// - iOS：Apple Vision（繁中、簡中、英文）
class OcrService {
  const OcrService();

  static const _channel = MethodChannel('photo_prompt/ocr');

  static bool get supported => Platform.isAndroid || Platform.isIOS;

  /// 辨識圖片檔中的文字；沒有文字回傳空字串。
  Future<String> recognize(String imagePath) async =>
      await _channel.invokeMethod<String>('recognize', {'path': imagePath}) ??
      '';
}
