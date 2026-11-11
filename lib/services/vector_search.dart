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

/// 向量平均後正規化；空清單回傳 null。
Float32List? meanVector(List<Float32List> vs) {
  if (vs.isEmpty) return null;
  final out = Float32List(vs.first.length);
  for (final v in vs) {
    for (var i = 0; i < out.length; i++) {
      out[i] += v[i];
    }
  }
  return l2Normalize(out);
}

/// Rocchio 查詢修正（O8）：往使用者選取（相關）的方向靠近，
/// 遠離看過但沒選（不相關）的方向。
Float32List rocchio(
  Float32List query,
  List<Float32List> positives,
  List<Float32List> negatives, {
  double alpha = 1.0,
  double beta = 0.75,
  double gamma = 0.15,
}) {
  final out = Float32List(query.length);
  final pos = meanVector(positives);
  final neg = meanVector(negatives);
  for (var i = 0; i < out.length; i++) {
    out[i] =
        alpha * query[i] +
        (pos == null ? 0 : beta * pos[i]) -
        (neg == null ? 0 : gamma * neg[i]);
  }
  return l2Normalize(out);
}

/// 相似照片分群（O6）。[vectors] 為每個項目的正規化向量（依 [times] 排序前的原順序），
/// 只比對拍攝時間相差 [windowSeconds] 秒以內的項目（null 表示全部兩兩比對）。
/// 回傳每群的索引（每群至少 2 個，依時間排序），群組依大小由大到小。
List<List<int>> similarGroups(
  List<Float32List> vectors,
  List<int> times, {
  double threshold = 0.95,
  int? windowSeconds = 6 * 3600,
}) {
  final n = vectors.length;
  final order = List<int>.generate(n, (i) => i)
    ..sort((a, b) => times[a].compareTo(times[b]));
  final parent = List<int>.generate(n, (i) => i);
  int find(int x) {
    while (parent[x] != x) {
      parent[x] = parent[parent[x]];
      x = parent[x];
    }
    return x;
  }

  for (var oi = 0; oi < n; oi++) {
    final a = order[oi];
    final va = vectors[a];
    for (var oj = oi + 1; oj < n; oj++) {
      final b = order[oj];
      if (windowSeconds != null && times[b] - times[a] > windowSeconds) break;
      final vb = vectors[b];
      var dot = 0.0;
      for (var k = 0; k < va.length; k++) {
        dot += va[k] * vb[k];
      }
      if (dot >= threshold) {
        final ra = find(a), rb = find(b);
        if (ra != rb) parent[rb] = ra;
      }
    }
  }

  final groups = <int, List<int>>{};
  for (final i in order) {
    groups.putIfAbsent(find(i), () => []).add(i);
  }
  return groups.values.where((g) => g.length > 1).toList()
    ..sort((a, b) => b.length.compareTo(a.length));
}
