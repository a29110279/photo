import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
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

/// 影像推論要測試的執行緒數：2、4、6、8 中不超過核心數者。
List<int> threadCandidates(int processors) {
  final out = [
    for (final t in const [2, 4, 6, 8])
      if (t <= processors) t,
  ];
  return out.isEmpty ? [processors.clamp(1, 4)] : out;
}

/// 影像推論的執行設定：首次啟動（或換模型）時在這支手機上實測選出，結果快取。
class InferenceTuning {
  const InferenceTuning({
    required this.threads,
    this.xnnpack = false,
    this.batch = 1,
    this.ms,
  });

  /// 快取格式版本；測速的項目有增減時遞增，舊快取會重測。
  static const format = 2;

  final int threads;

  /// 是否使用 XNNPACK 加速後端。
  final bool xnnpack;

  /// 一次推論的張數；1 表示逐張。
  final int batch;

  /// 實測每張影像的推論毫秒數。
  final double? ms;

  /// 顯示在設定頁的說明。
  String get label =>
      '$threads 執行緒'
      '${xnnpack ? '・XNNPACK' : ''}'
      '${batch > 1 ? '・批次 $batch' : ''}';

  Map<String, Object?> toJson() => {
    'threads': threads,
    'xnnpack': xnnpack,
    'batch': batch,
    'ms': ms,
  };

  static InferenceTuning fromJson(Map<dynamic, dynamic> j) => InferenceTuning(
    threads: j['threads'] as int,
    xnnpack: j['xnnpack'] as bool? ?? false,
    batch: j['batch'] as int? ?? 1,
    ms: (j['ms'] as num?)?.toDouble(),
  );
}

/// 候選設定至少快一成才採用：差距在量測誤差內時，維持較單純的設定。
bool clearlyFaster(double candidateMs, double baselineMs) =>
    candidateMs <= baselineMs * 0.9;

/// 裝置端 CLIP 推論（ONNX Runtime）。解碼用平台原生解碼器，推論在背景 Isolate 執行。
class EmbeddingService {
  EmbeddingService._(
    this.model,
    this._image,
    this._text,
    this._tokenizer,
    this.tuning,
  );

  /// 影像推論的執行設定（實測選出）。
  final InferenceTuning tuning;

  final InstalledModel model;
  final OrtSession _image;
  final OrtSession _text;
  final BertTokenizer _tokenizer;

  static Future<EmbeddingService> load(InstalledModel model) async {
    final imagePath = model.path('image');
    final textPath = model.path('text');
    final size = model.manifest.imageSize;
    final maxBatch = model.manifest.imageBatch;
    final processors = Platform.numberOfProcessors;
    final tuningFile = File('${model.dir}/tuning.json');
    // 測速期間存在的標記檔；啟動時還在，表示上次測速沒跑完。
    final marker = File('${model.dir}/tuning.running');
    final key = {
      'format': InferenceTuning.format,
      'version': model.manifest.version,
      'image': model.manifest.files['image']!.sha256,
      'processors': processors,
    };

    InferenceTuning? cached;
    try {
      final t = jsonDecode(await tuningFile.readAsString()) as Map;
      if (key.entries.every((e) => t[e.key] == e.value)) {
        cached = InferenceTuning.fromJson(t);
      }
    } on Object {
      cached = null;
    }
    // 上次測速中斷（可能是某個加速方式讓 App 當掉）：這次只測執行緒數，
    // 不再嘗試 XNNPACK 與批次，避免每次啟動都當在同一個地方。
    final interrupted = cached == null && await marker.exists();
    if (cached == null) {
      try {
        await marker.writeAsString('');
      } on Object {
        // 寫不進標記只是少一層保護。
      }
    }
    final candidates = threadCandidates(processors);

    // 建立 session（讀檔 + 圖最佳化）需要數秒且是同步呼叫，放在 UI isolate 會讓畫面卡住；
    // 改在另一個 isolate 建立，只把原生指標位址傳回來。
    final r = await Isolate.run(() {
      OrtEnv.instance.init();
      OrtSession open(String path, int threads, {bool xnnpack = false}) {
        final opts = OrtSessionOptions()
          ..setIntraOpNumThreads(threads)
          ..setSessionGraphOptimizationLevel(
            GraphOptimizationLevel.ortEnableAll,
          );
        try {
          if (xnnpack) opts.appendXnnpackProvider();
          return OrtSession.fromFile(File(path), opts);
        } finally {
          opts.release();
        }
      }

      ({int image, int text, InferenceTuning tuning}) result(
        OrtSession image,
        InferenceTuning tuning,
      ) => (
        image: image.address,
        text: open(textPath, tuning.threads.clamp(1, 4)).address,
        tuning: tuning,
      );

      final known = cached;
      if (known != null) {
        return result(
          open(imagePath, known.threads, xnnpack: known.xnnpack),
          known,
        );
      }

      // 1. 執行緒數：手機的大小核配置各不相同，固定值不一定最快。
      late OrtSession best;
      var threads = candidates.first;
      double? bestMs;
      for (final t in candidates) {
        final session = open(imagePath, t);
        final ms = _benchmark(session, size, 1);
        if (bestMs == null || ms < bestMs) {
          if (bestMs != null) best.release();
          best = session;
          threads = t;
          bestMs = ms;
        } else {
          session.release();
        }
      }
      var ms = bestMs!;
      var xnnpack = false;
      var batch = 1;
      if (!interrupted) {
        // 2. XNNPACK：針對 ARM 最佳化的運算後端，模型裡它支援的運算才會變快。
        try {
          final session = open(imagePath, threads, xnnpack: true);
          final t = _benchmark(session, size, 1);
          if (clearlyFaster(t, ms)) {
            best.release();
            best = session;
            xnnpack = true;
            ms = t;
          } else {
            session.release();
          }
        } on Object {
          // 這個 runtime 沒有 XNNPACK，或模型與它不相容：維持原設定。
        }
        // 3. 批次：一次推論多張，每張平均較快才採用。
        if (maxBatch > 1) {
          try {
            final t = _benchmark(best, size, maxBatch) / maxBatch;
            if (clearlyFaster(t, ms)) {
              batch = maxBatch;
              ms = t;
            }
          } on Object {
            // 模型不支援批次：逐張推論。
          }
        }
      }
      return result(
        best,
        InferenceTuning(
          threads: threads,
          xnnpack: xnnpack,
          batch: batch,
          ms: ms,
        ),
      );
    });
    if (cached == null) {
      try {
        await tuningFile.writeAsString(
          jsonEncode({...key, ...r.tuning.toJson()}),
        );
        await marker.delete();
      } on Object {
        // 寫不進去只是下次再測一次。
      }
    }
    OrtEnv.instance.init();
    final vocab = await File(model.path('vocab')).readAsString();
    return EmbeddingService._(
      model,
      OrtSession.fromAddress(r.image),
      OrtSession.fromAddress(r.text),
      BertTokenizer.fromVocabText(vocab),
      r.tuning,
    );
  }

  /// 以全零輸入實測一次推論 [batch] 張的平均毫秒數（先暖機一次）。
  static double _benchmark(OrtSession session, int size, int batch) {
    final input = OrtValueTensor.createTensorWithDataList(
      Float32List(batch * 3 * size * size),
      [batch, 3, size, size],
    );
    final options = OrtRunOptions();
    void once() {
      final out = session.run(options, {session.inputNames.first: input});
      for (final o in out) {
        o?.release();
      }
    }

    try {
      once();
      const runs = 3;
      final sw = Stopwatch()..start();
      for (var i = 0; i < runs; i++) {
        once();
      }
      return sw.elapsedMicroseconds / 1000 / runs;
    } finally {
      input.release();
      options.release();
    }
  }

  PreprocessSpec get _spec {
    final m = model.manifest;
    return PreprocessSpec(m.imageSize, m.mean, m.std, m.centerCrop);
  }

  /// 解碼與前處理（可與上一張的推論同時進行）。
  Future<PreparedImage?> prepare(Uint8List bytes) => prepareImage(bytes, _spec);

  /// 以前處理好的輸入推論。
  Future<Float32List?> embedPrepared(PreparedImage image) async {
    final s = model.manifest.imageSize;
    final rows = await _run(
      _image,
      OrtValueTensor.createTensorWithDataList(image.input, [1, 3, s, s]),
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// 推論多張：依實測選出的批次大小分批送進模型。
  /// 回傳與輸入同順序；推論失敗的那張為 null。
  Future<List<Float32List?>> embedPreparedAll(
    List<PreparedImage> images,
  ) async {
    final out = List<Float32List?>.filled(images.length, null);
    final s = model.manifest.imageSize;
    final per = 3 * s * s;
    for (var i = 0; i < images.length; i += tuning.batch) {
      final n = math.min(tuning.batch, images.length - i);
      var rows = const <Float32List>[];
      if (n > 1) {
        try {
          final input = Float32List(n * per);
          for (var k = 0; k < n; k++) {
            input.setAll(k * per, images[i + k].input);
          }
          rows = await _run(
            _image,
            OrtValueTensor.createTensorWithDataList(input, [n, 3, s, s]),
          );
        } on Object {
          rows = const [];
        }
      }
      for (var k = 0; k < n; k++) {
        if (rows.length == n) {
          out[i + k] = rows[k];
          continue;
        }
        // 單張，或整批失敗時逐張重試，避免一張壞圖拖累同批的其他張。
        try {
          out[i + k] = await embedPrepared(images[i + k]);
        } on Object {
          out[i + k] = null;
        }
      }
    }
    return out;
  }

  String get version => model.manifest.version;
  int get dim => model.manifest.embeddingDim;

  /// 影像（JPEG/PNG bytes）→ 已正規化的 embedding。
  Future<Float32List?> embedImage(Uint8List bytes) async {
    final prepared = await prepare(bytes);
    return prepared == null ? null : embedPrepared(prepared);
  }

  /// 文字 → 已正規化的 embedding。
  Future<Float32List?> embedText(String text) async {
    final n = model.manifest.contextLength;
    final ids = Int64List.fromList(_tokenizer.encode(text, contextLength: n));
    final rows = await _run(
      _text,
      OrtValueTensor.createTensorWithDataList(ids, [1, n]),
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// 執行模型，回傳每一列已正規化的 embedding。
  Future<List<Float32List>> _run(
    OrtSession session,
    OrtValueTensor input,
  ) async {
    final options = OrtRunOptions();
    List<OrtValue?>? outputs;
    try {
      outputs = await session.runAsync(options, {
        session.inputNames.first: input,
      });
      final value = outputs?.first?.value;
      if (value is! List) return const [];
      return [
        for (final row in value)
          l2Normalize(
            Float32List.fromList([
              for (final x in row as List) (x as num).toDouble(),
            ]),
          ),
      ];
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
