import 'dart:typed_data';

import '../data/local_store.dart';
import 'query_parser.dart';
import 'vector_search.dart';

class SearchHit {
  const SearchHit(this.asset, this.score, {this.excluded});
  final AssetRecord asset;

  /// cosine 相似度；純 metadata 查詢時為 null。
  final double? score;

  /// 與排除條件的最高相似度；沒有排除條件或該項目尚未索引時為 null。
  final double? excluded;
}

class SearchResult {
  const SearchResult(
    this.query,
    this.hits, {
    this.queryVector,
    this.byImage = false,
    this.refined = false,
    this.excludeVectors = const [],
  });
  final ParsedQuery query;

  /// 排除條件的文字向量（重新排序時沿用）。
  final List<Float32List> excludeVectors;

  /// 語意查詢所用的向量；純 metadata 查詢為 null。
  final Float32List? queryVector;

  /// 以圖搜圖（O7）：相似度分布與文字查詢不同，門檻分開設定。
  final bool byImage;

  /// 已依回饋修正過（O8）。
  final bool refined;

  /// 語意查詢依分數由高到低；純 metadata 查詢依時間新到舊。
  final List<SearchHit> hits;

  bool get isSemantic => queryVector != null;

  /// 結果是否受相關度門檻影響（語意查詢，或有排除條件）。
  bool get usesThreshold => isSemantic || excludeVectors.isNotEmpty;

  /// 套用相關度門檻（O2）：語意分數要達到門檻，
  /// 且與排除條件的相似度要低於同一個門檻。純 metadata 查詢不受分數影響。
  List<SearchHit> above(double threshold) => !usesThreshold
      ? hits
      : [
          for (final h in hits)
            if ((!isSemantic || (h.score ?? 0) >= threshold) &&
                (h.excluded ?? double.negativeInfinity) < threshold)
              h,
        ];

  /// 換一組項目，其餘不變（例如刪除後自結果移除）。
  SearchResult withHits(List<SearchHit> hits) => SearchResult(
    query,
    hits,
    queryVector: queryVector,
    byImage: byImage,
    refined: refined,
    excludeVectors: excludeVectors,
  );
}

/// 依拍攝月份把相鄰的項目分組（輸入需已依時間排序）。
List<({int year, int month, List<SearchHit> hits})> groupByMonth(
  List<SearchHit> hits,
) {
  final groups = <({int year, int month, List<SearchHit> hits})>[];
  for (final h in hits) {
    final d = DateTime.fromMillisecondsSinceEpoch(h.asset.createTs * 1000);
    if (groups.isEmpty ||
        groups.last.year != d.year ||
        groups.last.month != d.month) {
      groups.add((year: d.year, month: d.month, hits: [h]));
    } else {
      groups.last.hits.add(h);
    }
  }
  return groups;
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
    final q = await _parseWithPerson(input);
    final candidates = await store.filterAssets(q);

    // 排除條件需要模型；模型尚未就緒時先不排除。
    final negatives = <Float32List>[
      if (embedText != null && modelVersion != null)
        for (final t in q.exclude) ?await embedText(t),
    ];

    if (q.semantic.isEmpty || embedText == null || modelVersion == null) {
      // 沒有語意部分（或模型尚未就緒）且沒有任何條件時，不回傳整個相簿。
      if (!q.hasFilter) return SearchResult(q, const []);
      final hits = [for (final a in candidates) SearchHit(a, null)];
      return SearchResult(
        q,
        modelVersion == null
            ? hits
            : await _markExcluded(hits, negatives, modelVersion, dim),
        excludeVectors: negatives,
      );
    }

    final vec = await embedText(q.semantic);
    if (vec == null) return SearchResult(q, const []);
    final hits = await _rank(vec, candidates, q.hasFilter, modelVersion, dim);
    return SearchResult(
      q,
      await _markExcluded(hits, negatives, modelVersion, dim),
      queryVector: vec,
      excludeVectors: negatives,
    );
  }

  /// 為每個項目記下與排除條件的最高相似度（由 [SearchResult.above] 依門檻剔除）。
  Future<List<SearchHit>> _markExcluded(
    List<SearchHit> hits,
    List<Float32List> negatives,
    String modelVersion,
    int dim,
  ) async {
    if (negatives.isEmpty || hits.isEmpty) return hits;
    final matrix = await store.loadMatrix(modelVersion, dim);
    final ids = {for (final h in hits) h.asset.id};
    final worst = <String, double>{};
    for (final v in negatives) {
      matrix.score(v, allow: ids).forEach((id, s) {
        final prev = worst[id];
        if (prev == null || s > prev) worst[id] = s;
      });
    }
    return [
      for (final h in hits)
        SearchHit(h.asset, h.score, excluded: worst[h.asset.id]),
    ];
  }

  /// 提示詞中出現已命名的人物（O12）時，抽出名字作為人物條件。
  Future<ParsedQuery> _parseWithPerson(String input) async {
    final names = await store.personNameList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final name in names) {
      final i = input.indexOf(name);
      if (i < 0) continue;
      final rest = input.replaceRange(i, i + name.length, ' ');
      return parser.parse(rest).withPerson(name);
    }
    return parser.parse(input);
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
      await _markExcluded(hits, prev.excludeVectors, modelVersion, dim),
      queryVector: vec,
      byImage: prev.byImage,
      refined: true,
      excludeVectors: prev.excludeVectors,
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
