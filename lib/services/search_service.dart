import 'dart:typed_data';

import '../data/local_store.dart';
import 'query_parser.dart';
import 'vector_search.dart';

class SearchHit {
  const SearchHit(this.asset, this.score);
  final AssetRecord asset;

  /// cosine 相似度；純 metadata 查詢時為 null。
  final double? score;
}

class SearchResult {
  const SearchResult(
    this.query,
    this.hits, {
    this.queryVector,
    this.byImage = false,
    this.refined = false,
  });
  final ParsedQuery query;

  /// 語意查詢所用的向量；純 metadata 查詢為 null。
  final Float32List? queryVector;

  /// 以圖搜圖（O7）：相似度分布與文字查詢不同，門檻分開設定。
  final bool byImage;

  /// 已依回饋修正過（O8）。
  final bool refined;

  /// 語意查詢依分數由高到低；純 metadata 查詢依時間新到舊。
  final List<SearchHit> hits;

  bool get isSemantic => queryVector != null;

  /// 套用相關度門檻（O2）。純 metadata 查詢不受門檻影響。
  List<SearchHit> above(double threshold) => isSemantic
      ? hits.where((h) => (h.score ?? 0) >= threshold).toList()
      : hits;
}

/// 文字 → embedding 的介面（讓搜尋邏輯可在無模型下測試）。
typedef TextEmbedder = Future<Float32List?> Function(String text);

/// 混合式搜尋（全裝置端）：規則解析 → metadata 過濾 → 語意比對。
class SearchService {
  SearchService(this.store, {QueryParser? parser})
    : parser = parser ?? QueryParser();

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
    final hits = await _rank(vec, candidates, q.hasFilter, modelVersion, dim);
    return SearchResult(q, hits, queryVector: vec);
  }

  /// 以圖搜圖（O7）：以該項目的向量為查詢，排除自己。
  Future<SearchResult> searchByImage(
    String assetId, {
    required String modelVersion,
    required int dim,
  }) async {
    const q = ParsedQuery(raw: '以圖搜圖', semantic: '相似項目');
    final vec = await store.assetVector(assetId, modelVersion, dim);
    if (vec == null) throw StateError('此項目尚未索引，無法以圖搜圖');
    final candidates = await store.filterAssets(q);
    final hits = (await _rank(
      vec,
      candidates,
      false,
      modelVersion,
      dim,
    )).where((h) => h.asset.id != assetId).toList();
    return SearchResult(q, hits, queryVector: vec, byImage: true);
  }

  /// 回饋學習（O8）：[positives] 為使用者選取的結果，[negatives] 為看過但未選的結果。
  Future<SearchResult> refine(
    SearchResult prev, {
    required Set<String> positives,
    required Set<String> negatives,
    required String modelVersion,
    required int dim,
  }) async {
    final query = prev.queryVector;
    if (query == null) throw StateError('只有語意搜尋可以修正');
    Future<List<Float32List>> load(Set<String> ids) async => [
      for (final id in ids) ?await store.assetVector(id, modelVersion, dim),
    ];
    final vec = rocchio(query, await load(positives), await load(negatives));
    final candidates = await store.filterAssets(prev.query);
    final hits = await _rank(
      vec,
      candidates,
      prev.query.hasFilter,
      modelVersion,
      dim,
    );
    return SearchResult(
      prev.query,
      hits,
      queryVector: vec,
      byImage: prev.byImage,
      refined: true,
    );
  }

  Future<List<SearchHit>> _rank(
    Float32List vec,
    List<AssetRecord> candidates,
    bool restrict,
    String modelVersion,
    int dim,
  ) async {
    final matrix = await store.loadMatrix(modelVersion, dim);
    final byId = {for (final a in candidates) a.id: a};
    final scores = matrix.score(
      vec,
      allow: restrict ? byId.keys.toSet() : null,
    );
    return <SearchHit>[
      for (final e in scores.entries)
        if (byId[e.key] != null) SearchHit(byId[e.key]!, e.value),
    ]..sort((a, b) => b.score!.compareTo(a.score!));
  }
}
