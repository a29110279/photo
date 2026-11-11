import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// 模型清單中的單一檔案。
class ModelFile {
  const ModelFile({
    required this.url,
    required this.sha256,
    required this.size,
  });

  factory ModelFile.fromJson(Map<String, dynamic> j) => ModelFile(
    url: j['url'] as String,
    sha256: (j['sha256'] as String).toLowerCase(),
    size: (j['size'] as num?)?.toInt() ?? 0,
  );

  final String url;
  final String sha256;
  final int size;
}

/// 模型清單（manifest.json），由 tools/export_model.py 產生。
class ModelManifest {
  const ModelManifest({
    required this.version,
    required this.embeddingDim,
    required this.imageSize,
    required this.mean,
    required this.std,
    required this.centerCrop,
    required this.contextLength,
    required this.files,
  });

  factory ModelManifest.fromJson(Map<String, dynamic> j) {
    List<double> nums(String k) => [
      for (final v in j[k] as List) (v as num).toDouble(),
    ];
    final files = (j['files'] as Map<String, dynamic>).map(
      (k, v) => MapEntry(k, ModelFile.fromJson(v as Map<String, dynamic>)),
    );
    for (final k in fileKeys) {
      if (!files.containsKey(k)) throw FormatException('manifest 缺少檔案：$k');
    }
    final imageSize = j['imageSize'] as int;
    if (imageSize < 32 || imageSize > 2048) {
      throw FormatException('manifest 的 imageSize 不合理：$imageSize');
    }
    return ModelManifest(
      version: j['version'] as String,
      embeddingDim: j['embeddingDim'] as int,
      imageSize: imageSize,
      mean: nums('mean'),
      std: nums('std'),
      centerCrop: j['centerCrop'] as bool? ?? false,
      contextLength: j['contextLength'] as int,
      files: files,
    );
  }

  static const fileKeys = ['image', 'text', 'vocab'];

  final String version;
  final int embeddingDim;
  final int imageSize;
  final List<double> mean;
  final List<double> std;
  final bool centerCrop;
  final int contextLength;
  final Map<String, ModelFile> files;

  int get totalSize => files.values.fold(0, (a, f) => a + f.size);
}

/// 已安裝的模型：清單 + 本機檔案路徑。
class InstalledModel {
  const InstalledModel(this.manifest, this.dir);
  final ModelManifest manifest;
  final String dir;

  String path(String key) => p.join(dir, key);
}

/// 內建模型的資產路徑（由 Build APK workflow 放入，見 .github/workflows/build-apk.yml）。
const kBundledModelDir = 'assets/model';

/// 模型版本管理（C12）。模型隨 App 打包，首次啟動（或 App 更新換了模型）時
/// 從安裝檔解出到 App 資料夾，供 ONNX Runtime 以檔案路徑載入。完全不連網。
class ModelService {
  ModelService(this.rootDir);

  final String rootDir;

  File get _installedManifest => File(p.join(rootDir, 'manifest.json'));

  /// 讀取已解出的模型；檔案不齊則回傳 null。
  Future<InstalledModel?> installed() async {
    if (!await _installedManifest.exists()) return null;
    try {
      final m = ModelManifest.fromJson(
        jsonDecode(await _installedManifest.readAsString())
            as Map<String, dynamic>,
      );
      final dir = p.join(rootDir, m.version);
      for (final k in ModelManifest.fileKeys) {
        final f = File(p.join(dir, k));
        if (!await f.exists()) return null;
        final expected = m.files[k]!.size;
        if (expected > 0 && await f.length() != expected) return null;
      }
      return InstalledModel(m, dir);
    } on Object {
      return null;
    }
  }

  /// 確保內建模型已解出；版本相同則直接回傳。安裝檔未內建模型時回傳 null。
  /// [onProgress] 回報 0~1。
  Future<InstalledModel?> ensureBundled(
    AssetBundle bundle, {
    void Function(double progress)? onProgress,
  }) async {
    final String raw;
    try {
      raw = await bundle.loadString(
        '$kBundledModelDir/manifest.json',
        cache: false,
      );
    } on Object {
      return installed();
    }
    final manifest = ModelManifest.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
    final current = await installed();
    if (current != null && current.manifest.version == manifest.version) {
      return current;
    }

    final dir = Directory(p.join(rootDir, manifest.version));
    await dir.create(recursive: true);
    final keys = ModelManifest.fileKeys;
    for (var i = 0; i < keys.length; i++) {
      final key = keys[i];
      final data = await bundle.load('$kBundledModelDir/$key');
      final expected = manifest.files[key]!.size;
      if (expected > 0 && data.lengthInBytes != expected) {
        throw StateError('內建模型檔大小不符：$key');
      }
      final part = File(p.join(dir.path, '$key.part'));
      await part.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      await part.rename(p.join(dir.path, key));
      onProgress?.call((i + 1) / keys.length);
    }

    // 最後才寫 manifest：中途中斷時下次會重新解出。
    await _installedManifest.writeAsString(raw);
    await for (final e in Directory(rootDir).list()) {
      if (e is Directory && p.basename(e.path) != manifest.version) {
        await e.delete(recursive: true);
      }
    }
    return InstalledModel(manifest, dir.path);
  }
}
