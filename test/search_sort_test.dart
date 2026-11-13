import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_prompt/data/local_store.dart';
import 'package:photo_prompt/data/media_sizes.dart';
import 'package:photo_prompt/services/query_parser.dart';
import 'package:photo_prompt/services/search_service.dart';
import 'package:photo_prompt/state/providers.dart';

SearchHit hit(String id, DateTime taken, [double? score]) => SearchHit(
  AssetRecord(
    id: id,
    isVideo: false,
    createTs: taken.millisecondsSinceEpoch ~/ 1000,
    modifiedTs: 1,
  ),
  score,
);

void main() {
  const query = ParsedQuery(raw: '海邊', semantic: '海邊');
  final hits = [
    hit('mar', DateTime(2025, 3, 15), 0.9),
    hit('jan', DateTime(2025, 1, 2), 0.8),
    hit('mar2', DateTime(2025, 3, 1), 0.7),
  ];
  List<String> ids(SearchUiState s) => [for (final h in s.visible) h.asset.id];

  test('語意結果：預設依相關度，可改依時間', () {
    final result = SearchResult(query, hits, queryVector: Float32List(2));
    var s = SearchUiState(result: result, threshold: 0);
    expect(s.byTime, isFalse);
    expect(ids(s), ['mar', 'jan', 'mar2']);

    s = s.copyWith(sort: SearchSort.newest);
    expect(s.byTime, isTrue);
    expect(ids(s), ['mar', 'mar2', 'jan']);
    expect(ids(s.copyWith(sort: SearchSort.oldest)), ['jan', 'mar2', 'mar']);

    // 門檻仍然有效。
    expect(ids(s.copyWith(threshold: 0.75)), ['mar', 'jan']);
  });

  test('沒有語意分數的結果一律依時間，預設新到舊', () {
    final s = SearchUiState(result: SearchResult(query, hits));
    expect(s.byTime, isTrue);
    expect(ids(s), ['mar', 'mar2', 'jan']);
  });

  test('依月份分組', () {
    final s = SearchUiState(
      result: SearchResult(query, hits),
      sort: SearchSort.oldest,
    );
    final groups = groupByMonth(s.visible);
    expect(
      [for (final g in groups) (g.year, g.month, g.hits.length)],
      [(2025, 1, 1), (2025, 3, 2)],
    );
    expect(groupByMonth(const []), isEmpty);
  });

  test('檔案大小的顯示', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(1023), '1023 B');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
    expect(formatBytes(250 * 1024 * 1024), '250 MB');
    expect(formatBytes(3435973837), '3.2 GB');
  });
}
