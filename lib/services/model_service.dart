import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

/// 模型清單中的單一檔案。
class ModelFile {
  const ModelFile({required this.url, required this.sha256, required this.size});

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
    List<double> nums(String k) =>
        [for (final v in j[k] as List) (v as num).toDouble()];
    final files = (j['files'] as Map<String, dynamic>).map(
      (k, v) => MapEntry(k, ModelFile.fromJson(v as Map<String, dynamic>)),
    );
    for (final k in fileKeys) {
      if (!files.containsKey(k)) throw FormatException('manifest 缺少檔案：$k');
    }
    return ModelManifest(
      version: j['version'] as String,
      embeddingDim: j['embeddingDim'] as int,
      imageSize: j['imageSize'] as int,
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

/// 模型下載、校驗、版本管理（C12）。唯一的網路行為。
class ModelService {
  ModelService(this.rootDir, {Dio? dio}) : _dio = dio ?? Dio();

  final String rootDir;
  final Dio _dio;

  File get _installedManifest => File(p.join(rootDir, 'manifest.json'));

  /// 讀取已安裝的模型；檔案不齊則回傳 null。
  Future<InstalledModel?> installed() async {
    if (!await _installedManifest.exists()) return null;
    try {
      final m = ModelManifest.fromJson(
          jsonDecode(await _installedManifest.readAsString()) as Map<String, dynamic>);
      final dir = p.join(rootDir, m.version);
      for (final k in ModelManifest.fileKeys) {
        if (!await File(p.join(dir, k)).exists()) return null;
      }
      return InstalledModel(m, dir);
    } on Object {
      return null;
    }
  }

  /// 下載並安裝模型。支援斷點續傳與 SHA-256 校驗；[onProgress] 回報 0~1。
  Future<InstalledModel> install(
    String manifestUrl, {
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final raw = await _manifestJson(manifestUrl);
    final manifest =
        ModelManifest.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    final dir = Directory(p.join(rootDir, manifest.version));
    await dir.create(recursive: true);

    final total = manifest.totalSize;
    var finished = 0;
    for (final key in ModelManifest.fileKeys) {
      final f = manifest.files[key]!;
      final url = Uri.parse(manifestUrl).resolve(f.url).toString();
      await _download(
        url,
        File(p.join(dir.path, key)),
        f.sha256,
        cancelToken: cancelToken,
        onBytes: (n) {
          if (total > 0) onProgress?.call(((finished + n) / total).clamp(0, 1));
        },
      );
      finished += f.size;
    }

    await _installedManifest.writeAsString(raw);
    // 清掉舊版本
    await for (final e in Directory(rootDir).list()) {
      if (e is Directory && p.basename(e.path) != manifest.version) {
        await e.delete(recursive: true);
      }
    }
    return InstalledModel(manifest, dir.path);
  }

  Future<String> _manifestJson(String url) async {
    final r = await _dio.get<String>(url,
        options: Options(responseType: ResponseType.plain));
    return r.data!;
  }

  Future<void> _download(
    String url,
    File target,
    String sha256Hex, {
    required void Function(int bytes) onBytes,
    CancelToken? cancelToken,
  }) async {
    if (await target.exists() && await _sha256(target) == sha256Hex) {
      onBytes(await target.length());
      return;
    }
    final part = File('${target.path}.part');
    var offset = await part.exists() ? await part.length() : 0;

    final resp = await _dio.get<ResponseBody>(
      url,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.stream,
        headers: {if (offset > 0) 'Range': 'bytes=$offset-'},
        // 416：.part 已是完整檔案，交給校驗判定。
        validateStatus: (s) => s == 200 || s == 206 || s == 416,
      ),
    );
    if (resp.statusCode != 416) {
      // 伺服器不支援 Range 時會回 200，需從頭寫。
      if (resp.statusCode == 200) offset = 0;
      final sink = part.openWrite(
          mode: offset > 0 ? FileMode.append : FileMode.write);
      try {
        await for (final chunk in resp.data!.stream) {
          sink.add(chunk);
          offset += chunk.length;
          onBytes(offset);
        }
      } finally {
        await sink.close();
      }
    }

    if (await _sha256(part) != sha256Hex) {
      await part.delete();
      throw StateError('模型檔校驗失敗（SHA-256 不符）：$url');
    }
    await part.rename(target.path);
  }

  static Future<String> _sha256(File f) async =>
      (await sha256.bind(f.openRead()).first).toString();
}
