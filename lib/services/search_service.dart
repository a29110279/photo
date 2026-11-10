import 'dart:typed_data';

import '../data/local_store.dart';
import 'query_parser.dart';

class SearchHit {
  const SearchHit(this.asset, this.score);
  final AssetRecord asset;

  /// cosine 相似度；純 metadata 查詢時為 null。
  final double? score;
}

class SearchResult {
  const SearchResult(this.query, this.hits);
  final ParsedQuery query;

  /// 語意查詢依分數由高到低；純 metadata 查詢依時間新到舊。
  final List<SearchHit> hits;

  bool get isSemantic => query.semantic.isNotEmpty;

  /// 套用相關度門檻（O2）。純 metadata 查詢不受門檻影響。
  List<SearchHit> above(double threshold) => isSemantic
      ? hits.where((h) => (h.score ?? 0) >= threshold).toList()
      : hits;
}

/// 文字 → embedding 的介面（讓搜尋邏輯可在無模型下測試）。
typedef TextEmbedder = Future<Float32List?> Function(String text);

/// 混合式搜尋（全裝置端）：規則解析 → metadata 過濾 → 語意比對。
class SearchService {
  SearchService(this.store, {QueryParser? parser}) : parser = parser ?? QueryParser();

  final LocalStore store;
  final QueryParser parser;

  Future<SearchResult> search(
    String input, {
    TextEmbedder? embedText,
    String? modelVersion,
    int dim = 0,
  }) async {
    final q = parser.parse(input);
    final candidates = await store.filterAssets(q);

    if (q.semantic.isEmpty || embedText == null || modelVersion == null) {
      // 沒有語意部分（或模型尚未就緒）且沒有任何條件時，不回傳整個相簿。
      if (!q.hasFilter) return SearchResult(q, const []);
      return SearchResult(q, [for (final a in candidates) SearchHit(a, null)]);
    }

    final vec = await embedText(q.semantic);
    if (vec == null) return SearchResult(q, const []);
    final matrix = await store.loadMatrix(modelVersion, dim);
    final byId = {for (final a in candidates) a.id: a};
    final scores = matrix.score(vec, allow: q.hasFilter ? byId.keys.toSet() : null);
    final hits = <SearchHit>[
      for (final e in scores.entries)
        if (byId[e.key] != null) SearchHit(byId[e.key]!, e.value),
    ]..sort((a, b) => b.score!.compareTo(a.score!));
    return SearchResult(q, hits);
  }
}
