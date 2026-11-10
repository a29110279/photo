import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';

import 'bert_tokenizer.dart';
import 'model_service.dart';
import 'vector_search.dart';

/// 影像前處理參數（可跨 Isolate 傳遞）。
class PreprocessSpec {
  const PreprocessSpec(this.size, this.mean, this.std, this.centerCrop);
  final int size;
  final List<double> mean;
  final List<double> std;
  final bool centerCrop;
}

/// 解碼 → 縮放 → 正規化為 NCHW float32。解碼失敗回傳 null。
Float32List? preprocessImage(Uint8List bytes, PreprocessSpec spec) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  final s = spec.size;
  final resized = spec.centerCrop
      ? img.copyResizeCropSquare(decoded,
          size: s, interpolation: img.Interpolation.cubic)
      : img.copyResize(decoded,
          width: s, height: s, interpolation: img.Interpolation.cubic);
  final out = Float32List(3 * s * s);
  final plane = s * s;
  var i = 0;
  for (final px in resized) {
    out[i] = (px.r / 255.0 - spec.mean[0]) / spec.std[0];
    out[plane + i] = (px.g / 255.0 - spec.mean[1]) / spec.std[1];
    out[2 * plane + i] = (px.b / 255.0 - spec.mean[2]) / spec.std[2];
    i++;
  }
  return out;
}

/// 獨立成頂層函式：closure 只會捕捉 bytes 與 spec，
/// 不會連帶把含原生指標的 session 送進 Isolate。
Future<Float32List?> _preprocessInIsolate(Uint8List bytes, PreprocessSpec spec) =>
    Isolate.run(() => preprocessImage(bytes, spec));

/// 裝置端 CLIP 推論（ONNX Runtime）。影像前處理與推論皆在背景 Isolate 執行。
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
    final input = await _preprocessInIsolate(bytes, spec);
    if (input == null) return null;
    final tensor = OrtValueTensor.createTensorWithDataList(
        input, [1, 3, m.imageSize, m.imageSize]);
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
      outputs = await session.runAsync(options, {session.inputNames.first: input});
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
