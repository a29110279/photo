import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:onnxruntime/onnxruntime.dart';

import 'bert_tokenizer.dart';
import 'model_service.dart';
import 'vector_search.dart';

/// 影像前處理參數。
class PreprocessSpec {
  const PreprocessSpec(this.size, this.mean, this.std, this.centerCrop);
  final int size;
  final List<double> mean;
  final List<double> std;
  final bool centerCrop;
}

/// RGBA 像素 → 正規化的 NCHW float32。
///
/// [rgba] 為 [width]×[height] 的像素。centerCrop 時取中央 size×size，
/// 否則影像應已縮放為 size×size。
Float32List normalizeRgba(
  Uint8List rgba,
  int width,
  int height,
  PreprocessSpec spec,
) {
  final s = spec.size;
  final x0 = spec.centerCrop ? (width - s) ~/ 2 : 0;
  final y0 = spec.centerCrop ? (height - s) ~/ 2 : 0;
  final out = Float32List(3 * s * s);
  final plane = s * s;
  final m0 = spec.mean[0], m1 = spec.mean[1], m2 = spec.mean[2];
  final d0 = 255.0 * spec.std[0],
      d1 = 255.0 * spec.std[1],
      d2 = 255.0 * spec.std[2];
  final s0 = spec.std[0], s1 = spec.std[1], s2 = spec.std[2];
  var i = 0;
  for (var y = 0; y < s; y++) {
    var p = ((y0 + y) * width + x0) * 4;
    for (var x = 0; x < s; x++, p += 4, i++) {
      out[i] = rgba[p] / d0 - m0 / s0;
      out[plane + i] = rgba[p + 1] / d1 - m1 / s1;
      out[2 * plane + i] = rgba[p + 2] / d2 - m2 / s2;
    }
  }
  return out;
}

/// 以平台原生解碼器（Flutter engine）解碼並縮放，比純 Dart 解碼快得多。
/// 解碼失敗回傳 null。
Future<Float32List?> preprocessImage(
  Uint8List bytes,
  PreprocessSpec spec,
) async {
  final s = spec.size;
  ui.Codec? codec;
  ui.Image? image;
  try {
    if (spec.centerCrop) {
      // 先讀尺寸，短邊縮到 s，再取中央。
      final descriptor = await ui.ImageDescriptor.encoded(
        await ui.ImmutableBuffer.fromUint8List(bytes),
      );
      final w = descriptor.width, h = descriptor.height;
      final scale = s / (w < h ? w : h);
      codec = await descriptor.instantiateCodec(
        targetWidth: (w * scale).round().clamp(s, 1 << 15),
        targetHeight: (h * scale).round().clamp(s, 1 << 15),
      );
    } else {
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: s,
        targetHeight: s,
        allowUpscaling: true,
      );
    }
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    return normalizeRgba(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      image.width,
      image.height,
      spec,
    );
  } on Object {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}

/// 裝置端 CLIP 推論（ONNX Runtime）。解碼用平台原生解碼器，推論在背景 Isolate 執行。
class EmbeddingService {
  EmbeddingService._(this.model, this._image, this._text, this._tokenizer);

  final InstalledModel model;
  final OrtSession _image;
  final OrtSession _text;
  final BertTokenizer _tokenizer;

  static Future<EmbeddingService> load(InstalledModel model) async {
    OrtEnv.instance.init();
    OrtSession open(String key) {
      final opts = OrtSessionOptions()
        ..setIntraOpNumThreads(Platform.numberOfProcessors.clamp(1, 4))
        ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);
      return OrtSession.fromFile(File(model.path(key)), opts);
    }

    final vocab = await File(model.path('vocab')).readAsString();
    return EmbeddingService._(
      model,
      open('image'),
      open('text'),
      BertTokenizer.fromVocabText(vocab),
    );
  }

  String get version => model.manifest.version;
  int get dim => model.manifest.embeddingDim;

  /// 影像（JPEG/PNG bytes）→ 已正規化的 embedding。
  Future<Float32List?> embedImage(Uint8List bytes) async {
    final m = model.manifest;
    final spec = PreprocessSpec(m.imageSize, m.mean, m.std, m.centerCrop);
    final input = await preprocessImage(bytes, spec);
    if (input == null) return null;
    final tensor = OrtValueTensor.createTensorWithDataList(input, [
      1,
      3,
      m.imageSize,
      m.imageSize,
    ]);
    return _run(_image, tensor);
  }

  /// 文字 → 已正規化的 embedding。
  Future<Float32List?> embedText(String text) {
    final n = model.manifest.contextLength;
    final ids = Int64List.fromList(_tokenizer.encode(text, contextLength: n));
    return _run(_text, OrtValueTensor.createTensorWithDataList(ids, [1, n]));
  }

  Future<Float32List?> _run(OrtSession session, OrtValueTensor input) async {
    final options = OrtRunOptions();
    List<OrtValue?>? outputs;
    try {
      outputs = await session.runAsync(options, {
        session.inputNames.first: input,
      });
      final value = outputs?.first?.value;
      if (value is! List || value.isEmpty) return null;
      final row = value.first as List;
      final v = Float32List(row.length);
      for (var i = 0; i < row.length; i++) {
        v[i] = (row[i] as num).toDouble();
      }
      return l2Normalize(v);
    } finally {
      input.release();
      options.release();
      outputs?.forEach((o) => o?.release());
    }
  }

  void dispose() {
    _image.release();
    _text.release();
  }
}
