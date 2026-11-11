import 'dart:io';
import 'dart:isolate';
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

/// 前處理結果：模型輸入與清晰度。
class PreparedImage {
  const PreparedImage(this.input, this.sharpness);
  final Float32List input;

  /// Laplacian 變異數，越小越模糊（O10）。
  final double sharpness;
}

/// 灰階 Laplacian 變異數：常用的模糊程度指標，數值越小越模糊。
double laplacianVariance(Uint8List rgba, int width, int height) {
  if (width < 3 || height < 3) return 0;
  final gray = Float64List(width * height);
  for (var i = 0, p = 0; i < gray.length; i++, p += 4) {
    gray[i] = 0.299 * rgba[p] + 0.587 * rgba[p + 1] + 0.114 * rgba[p + 2];
  }
  var sum = 0.0, sumSq = 0.0;
  var n = 0;
  for (var y = 1; y < height - 1; y++) {
    for (var x = 1; x < width - 1; x++) {
      final i = y * width + x;
      final v =
          gray[i - 1] +
          gray[i + 1] +
          gray[i - width] +
          gray[i + width] -
          4 * gray[i];
      sum += v;
      sumSq += v * v;
      n++;
    }
  }
  final mean = sum / n;
  return sumSq / n - mean * mean;
}

/// 以平台原生解碼器（Flutter engine）解碼並縮放，比純 Dart 解碼快得多。
/// 解碼失敗回傳 null。
Future<Float32List?> preprocessImage(
  Uint8List bytes,
  PreprocessSpec spec,
) async => (await prepareImage(bytes, spec))?.input;

/// 解碼、縮放、正規化，並計算清晰度。解碼失敗回傳 null。
Future<PreparedImage?> prepareImage(
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
    final rgba = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    return PreparedImage(
      normalizeRgba(rgba, image.width, image.height, spec),
      laplacianVariance(rgba, image.width, image.height),
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
    final imagePath = model.path('image');
    final textPath = model.path('text');
    final threads = Platform.numberOfProcessors.clamp(1, 4);
    // 建立 session（讀檔 + 圖最佳化）需要數秒且是同步呼叫，放在 UI isolate 會讓畫面卡住；
    // 改在另一個 isolate 建立，只把原生指標位址傳回來。
    final addresses = await Isolate.run(() {
      OrtEnv.instance.init();
      int open(String path) {
        final opts = OrtSessionOptions()
          ..setIntraOpNumThreads(threads)
          ..setSessionGraphOptimizationLevel(
            GraphOptimizationLevel.ortEnableAll,
          );
        try {
          return OrtSession.fromFile(File(path), opts).address;
        } finally {
          opts.release();
        }
      }

      return [open(imagePath), open(textPath)];
    });
    OrtEnv.instance.init();
    final vocab = await File(model.path('vocab')).readAsString();
    return EmbeddingService._(
      model,
      OrtSession.fromAddress(addresses[0]),
      OrtSession.fromAddress(addresses[1]),
      BertTokenizer.fromVocabText(vocab),
    );
  }

  PreprocessSpec get _spec {
    final m = model.manifest;
    return PreprocessSpec(m.imageSize, m.mean, m.std, m.centerCrop);
  }

  /// 解碼與前處理（可與上一張的推論同時進行）。
  Future<PreparedImage?> prepare(Uint8List bytes) => prepareImage(bytes, _spec);

  /// 以前處理好的輸入推論。
  Future<Float32List?> embedPrepared(PreparedImage image) {
    final s = model.manifest.imageSize;
    return _run(
      _image,
      OrtValueTensor.createTensorWithDataList(image.input, [1, 3, s, s]),
    );
  }

  String get version => model.manifest.version;
  int get dim => model.manifest.embeddingDim;

  /// 影像（JPEG/PNG bytes）→ 已正規化的 embedding。
  Future<Float32List?> embedImage(Uint8List bytes) async {
    final prepared = await prepare(bytes);
    return prepared == null ? null : embedPrepared(prepared);
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
