import 'dart:math' as math;
import 'dart:typed_data';

/// L2 正規化（就地修改並回傳）。
Float32List l2Normalize(Float32List v) {
  var sum = 0.0;
  for (final x in v) {
    sum += x * x;
  }
  final norm = math.sqrt(sum);
  if (norm == 0) return v;
  for (var i = 0; i < v.length; i++) {
    v[i] = v[i] / norm;
  }
  return v;
}

/// 記憶體內的 embedding 矩陣（已正規化），供暴力比對。
/// 一個 asset 可有多列（影片多幀），搜尋時取最高分。
class EmbeddingMatrix {
  EmbeddingMatrix(this.dim, this.assetIds, this.data)
      : assert(data.length == assetIds.length * dim);

  final int dim;
  final List<String> assetIds;
  final Float32List data;

  int get rows => assetIds.length;

  /// 回傳每個 asset 的最高 cosine 相似度。[allow] 為候選集（null 表示全部）。
  Map<String, double> score(Float32List query, {Set<String>? allow}) {
    assert(query.length == dim);
    final out = <String, double>{};
    for (var r = 0; r < rows; r++) {
      final id = assetIds[r];
      if (allow != null && !allow.contains(id)) continue;
      final base = r * dim;
      var dot = 0.0;
      for (var i = 0; i < dim; i++) {
        dot += data[base + i] * query[i];
      }
      final prev = out[id];
      if (prev == null || dot > prev) out[id] = dot;
    }
    return out;
  }
}
