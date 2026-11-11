import '../data/local_store.dart';
import 'album_service.dart';
import 'search_service.dart';

/// 智慧相簿（O5）：儲存提示詞與門檻，之後符合的新項目可一鍵加入。
///
/// Android 的搬移需要系統授權框，無法完全自動執行；
/// 因此索引完成後只計算「待加入」數量，由使用者按一下套用。
class SmartAlbumService {
  SmartAlbumService(this.store, this.search, this.albums);

  final LocalStore store;
  final SearchService search;
  final AlbumService albums;

  /// 符合規則、但尚未處理的項目 id（依相關度排序）。
  Future<List<String>> pending(
    SmartAlbum rule, {
    TextEmbedder? embedText,
    String? modelVersion,
    int dim = 0,
  }) async {
    final r = await search.search(
      rule.prompt,
      embedText: embedText,
      modelVersion: modelVersion,
      dim: dim,
    );
    final done = await store.smartAlbumProcessed(rule.id);
    return [
      for (final h in r.above(rule.threshold))
        if (!done.contains(h.asset.id)) h.asset.id,
    ];
  }

  /// 把 [ids] 加入相簿；[skipped] 為使用者取消勾選的項目，之後不再提示。
  Future<AlbumResult?> apply(
    SmartAlbum rule,
    List<String> ids, {
    List<String> skipped = const [],
  }) async {
    AlbumResult? result;
    if (ids.isNotEmpty) {
      try {
        result = await albums.addToAlbum(rule.name, ids);
      } on AlreadyInAlbumException {
        // 已在相簿中：視為處理完成。
      }
    }
    await store.markSmartAlbumProcessed(rule.id, [...ids, ...skipped]);
    return result;
  }
}
