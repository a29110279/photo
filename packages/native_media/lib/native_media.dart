/// App 自用的原生功能（OCR、影片抽幀）。
///
/// 以外掛形式提供，背景索引的 Flutter 引擎也會自動註冊這些通道。
/// Dart 端的呼叫在 App 的 `lib/services/ocr_service.dart` 與
/// `lib/data/video_frames.dart`，通道名稱為 `photo_prompt/ocr`、`photo_prompt/media`。
library;
