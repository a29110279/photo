/// 存在 LocalStore（kv 表）的設定鍵。前景與背景索引共用。
abstract final class SettingKeys {
  /// 前景 App 的心跳時間（毫秒）；背景索引看到最近的心跳就不執行。
  static const foregroundHeartbeat = 'fg_heartbeat';

  /// 上次完整列舉時的媒體庫指紋。
  static const mediaSignature = 'media_signature';
  static const threshold = 'threshold';
  static const imageThreshold = 'image_threshold';
  static const ocrEnabled = 'ocr_enabled';
}
