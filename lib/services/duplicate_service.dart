import 'dart:isolate';
import 'dart:typed_data';

import '../data/local_store.dart';
import 'query_parser.dart';
import 'vector_search.dart';

/// 重複／相似照片偵測（O6），沿用語意 embedding，不需額外模型。
class DuplicateService {
  DuplicateService(this.store);
  final LocalStore store;

  /// 回傳相似群組（asset id，依拍攝時間排序）。
  /// [threshold] 越高越嚴格；0.95 以上多為連拍或重複存檔。
  /// [windowHours] 為 null 時全部兩兩比對（1 萬張約需數十秒）。
  Future<List<List<String>>> findGroups({
    required String modelVersion,
    required int dim,
    double threshold = 0.95,
    int? windowHours = 6,
  }) async {
    final matrix = await store.loadMatrix(modelVersion, dim);
    final photos = {
      for (final a in await store.filterAssets(
        const ParsedQuery(raw: '', kind: MediaKind.image),
      ))
        a.id: a.createTs,
    };

    // 每個相片取第一幀（相片只有一幀）。
    final ids = <String>[];
    final vectors = <Float32List>[];
    final times = <int>[];
    final seen = <String>{};
    for (var r = 0; r < matrix.rows; r++) {
      final id = matrix.assetIds[r];
      final ts = photos[id];
      if (ts == null || !seen.add(id)) continue;
      ids.add(id);
      times.add(ts);
      vectors.add(Float32List.sublistView(matrix.data, r * dim, (r + 1) * dim));
    }

    final window = windowHours == null ? null : windowHours * 3600;
    final groups = await Isolate.run(
      () => similarGroups(
        vectors,
        times,
        threshold: threshold,
        windowSeconds: window,
      ),
    );
    return [
      for (final g in groups) [for (final i in g) ids[i]],
    ];
  }
}
