import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:path/path.dart' as p;

import 'model_service.dart';
import 'vector_search.dart';

/// 人臉框（0~1 比例，原點左上）。
class FaceBox {
  const FaceBox(this.left, this.top, this.width, this.height);
  final double left, top, width, height;

  String encode() =>
      [left, top, width, height].map((v) => v.toStringAsFixed(4)).join(',');

  static FaceBox decode(String s) {
    final v = s.split(',').map(double.parse).toList();
    return FaceBox(v[0], v[1], v[2], v[3]);
  }
}

class DetectedFace {
  const DetectedFace(this.box, this.vector);
  final FaceBox box;

  /// 已 L2 正規化的人臉特徵。
  final Float32List vector;
}

/// 從 RGBA 影像裁出人臉（含 [margin] 比例的邊界、取正方形），
/// 以雙線性內插縮放為 [size]×[size]，正規化為 (x - mean) / scale 的 NCHW。
Float32List cropFace(
  Uint8List rgba,
  int width,
  int height,
  FaceBox box, {
  int size = 160,
  double mean = 127.5,
  double scale = 128,
  double margin = 0.2,
}) {
  final cx = (box.left + box.width / 2) * width;
  final cy = (box.top + box.height / 2) * height;
  final side =
      (box.width * width > box.height * height
          ? box.width * width
          : box.height * height) *
      (1 + margin);
  final x0 = cx - side / 2, y0 = cy - side / 2;
  final out = Float32List(3 * size * size);
  final plane = size * size;
  double sample(double x, double y, int c) {
    final xc = x.clamp(0, width - 1).toDouble();
    final yc = y.clamp(0, height - 1).toDouble();
    final xi = xc.floor(), yi = yc.floor();
    final x1 = xi + 1 < width ? xi + 1 : xi;
    final y1 = yi + 1 < height ? yi + 1 : yi;
    final fx = xc - xi, fy = yc - yi;
    int px(int x, int y) => rgba[(y * width + x) * 4 + c];
    final top = px(xi, yi) * (1 - fx) + px(x1, yi) * fx;
    final bottom = px(xi, y1) * (1 - fx) + px(x1, y1) * fx;
    return top * (1 - fy) + bottom * fy;
  }

  final step = side / size;
  for (var j = 0; j < size; j++) {
    final y = y0 + (j + 0.5) * step - 0.5;
    for (var i = 0; i < size; i++) {
      final x = x0 + (i + 0.5) * step - 0.5;
      final k = j * size + i;
      out[k] = (sample(x, y, 0) - mean) / scale;
      out[plane + k] = (sample(x, y, 1) - mean) / scale;
      out[2 * plane + k] = (sample(x, y, 2) - mean) / scale;
    }
  }
  return out;
}

/// 人臉偵測 + 特徵（O12）。偵測用平台原生 API，特徵用內建的 ONNX 模型。
class FaceService {
  FaceService._(
    this.version,
    this._session,
    this._size,
    this._mean,
    this._scale,
  );

  final String version;
  final OrtSession _session;
  final int _size;
  final double _mean;
  final double _scale;

  static const _channel = MethodChannel('photo_prompt/media');
  static const _asset = '$kBundledModelDir/face';
  static const _manifestAsset = '$kBundledModelDir/face_manifest.json';

  /// 單張相片最多處理的人臉數，避免團體照拖慢索引。
  static const maxFaces = 8;

  /// 太小的人臉特徵不可靠，略過。
  static const minFaceSize = 0.08;

  /// 載入內建的人臉模型（必要時先解出到 [dir]）；安裝檔未內建則回傳 null。
  static Future<FaceService?> load(AssetBundle bundle, String dir) async {
    final String raw;
    try {
      raw = await bundle.loadString(_manifestAsset, cache: false);
    } on Object {
      return null;
    }
    final m = jsonDecode(raw) as Map<String, dynamic>;
    final size = (m['files']['face']['size'] as num).toInt();
    final file = File(p.join(dir, 'face-${m['version']}.onnx'));
    if (!await file.exists() || await file.length() != size) {
      await Directory(dir).create(recursive: true);
      final data = await bundle.load(_asset);
      final part = File('${file.path}.part');
      await part.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      await part.rename(file.path);
    }
    final path = file.path;
    final address = await Isolate.run(() {
      OrtEnv.instance.init();
      final opts = OrtSessionOptions()
        ..setIntraOpNumThreads(Platform.numberOfProcessors.clamp(1, 4))
        ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);
      try {
        return OrtSession.fromFile(File(path), opts).address;
      } finally {
        opts.release();
      }
    });
    OrtEnv.instance.init();
    return FaceService._(
      m['version'] as String,
      OrtSession.fromAddress(address),
      (m['inputSize'] as num).toInt(),
      (m['mean'] as num).toDouble(),
      (m['scale'] as num).toDouble(),
    );
  }

  /// 偵測並計算一張相片（JPEG bytes）中所有人臉的特徵。
  Future<List<DetectedFace>> process(Uint8List jpeg) async {
    final dir = await Directory.systemTemp.createTemp('face');
    try {
      final file = await File('${dir.path}/image.jpg').writeAsBytes(jpeg);
      final raw = await _channel.invokeListMethod<List<Object?>>(
        'detectFaces',
        {'path': file.path},
      );
      final boxes =
          [
                for (final b in raw ?? const <List<Object?>>[])
                  FaceBox(
                    (b[0]! as num).toDouble(),
                    (b[1]! as num).toDouble(),
                    (b[2]! as num).toDouble(),
                    (b[3]! as num).toDouble(),
                  ),
              ]
              .where((b) => b.width >= minFaceSize && b.height >= minFaceSize)
              .toList()
            ..sort(
              (a, b) => (b.width * b.height).compareTo(a.width * a.height),
            );
      if (boxes.isEmpty) return const [];

      final codec = await ui.instantiateImageCodec(jpeg);
      final image = (await codec.getNextFrame()).image;
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (data == null) return const [];
        final rgba = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
        final out = <DetectedFace>[];
        for (final box in boxes.take(maxFaces)) {
          final input = cropFace(
            rgba,
            image.width,
            image.height,
            box,
            size: _size,
            mean: _mean,
            scale: _scale,
          );
          final v = await _embed(input);
          if (v != null) out.add(DetectedFace(box, v));
        }
        return out;
      } finally {
        image.dispose();
        codec.dispose();
      }
    } finally {
      await dir.delete(recursive: true);
    }
  }

  Future<Float32List?> _embed(Float32List input) async {
    final tensor = OrtValueTensor.createTensorWithDataList(input, [
      1,
      3,
      _size,
      _size,
    ]);
    final options = OrtRunOptions();
    List<OrtValue?>? outputs;
    try {
      outputs = await _session.runAsync(options, {
        _session.inputNames.first: tensor,
      });
      final value = outputs?.first?.value;
      if (value is! List || value.isEmpty) return null;
      final row = value.first as List;
      return l2Normalize(
        Float32List.fromList([for (final x in row) (x as num).toDouble()]),
      );
    } finally {
      tensor.release();
      options.release();
      outputs?.forEach((o) => o?.release());
    }
  }

  void dispose() => _session.release();
}

/// 人臉分群（O12）：依序把每張臉指派給最相似的群（與群中心的 cosine ≥ [threshold]），
/// 否則自成一群。回傳每張臉的群編號。
List<int> clusterFaces(List<Float32List> vectors, {double threshold = 0.6}) {
  final labels = List<int>.filled(vectors.length, -1);
  final sums = <Float32List>[];
  final centroids = <Float32List>[];
  for (var i = 0; i < vectors.length; i++) {
    final v = vectors[i];
    var best = -1;
    var bestScore = threshold;
    for (var c = 0; c < centroids.length; c++) {
      final cen = centroids[c];
      var dot = 0.0;
      for (var k = 0; k < v.length; k++) {
        dot += v[k] * cen[k];
      }
      if (dot >= bestScore) {
        bestScore = dot;
        best = c;
      }
    }
    if (best < 0) {
      sums.add(Float32List.fromList(v));
      centroids.add(Float32List.fromList(v));
      labels[i] = centroids.length - 1;
    } else {
      final sum = sums[best];
      for (var k = 0; k < v.length; k++) {
        sum[k] += v[k];
      }
      centroids[best] = l2Normalize(Float32List.fromList(sum));
      labels[i] = best;
    }
  }
  return labels;
}
