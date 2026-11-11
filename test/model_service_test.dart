import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_prompt/services/model_service.dart';

/// 以記憶體內容模擬 App 內建的資產。
class FakeBundle extends CachingAssetBundle {
  FakeBundle(this.files);
  final Map<String, List<int>> files;
  /// 模型檔（不含 manifest）被讀取的次數。
  int loads = 0;

  @override
  Future<ByteData> load(String key) async {
    final f = files[key];
    if (f == null) throw StateError('missing $key');
    if (!key.endsWith('manifest.json')) loads++;
    return ByteData.sublistView(Uint8List.fromList(f));
  }
}

Map<String, List<int>> bundleFor(String version, {int bump = 0}) {
  final contents = {
    'image': List<int>.filled(10 + bump, 1),
    'text': List<int>.filled(20 + bump, 2),
    'vocab': utf8.encode('[PAD]\n[UNK]\n'),
  };
  final manifest = {
    'version': version,
    'embeddingDim': 512,
    'imageSize': 224,
    'mean': [0.5, 0.5, 0.5],
    'std': [0.5, 0.5, 0.5],
    'contextLength': 52,
    'files': {
      for (final e in contents.entries)
        e.key: {'url': e.key, 'sha256': 'x', 'size': e.value.length},
    },
  };
  return {
    '$kBundledModelDir/manifest.json': utf8.encode(jsonEncode(manifest)),
    for (final e in contents.entries) '$kBundledModelDir/${e.key}': e.value,
  };
}

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('models'));
  tearDown(() => dir.delete(recursive: true));

  test('首次啟動解出內建模型，之後直接使用', () async {
    final svc = ModelService(dir.path);
    final progress = <double>[];
    final bundle = FakeBundle(bundleFor('v1'));
    final m = (await svc.ensureBundled(bundle, onProgress: progress.add))!;
    expect(m.manifest.version, 'v1');
    expect(await File(m.path('text')).length(), 20);
    expect(progress.last, 1.0);

    final loadsAfterFirst = bundle.loads;
    final again = await svc.ensureBundled(bundle);
    expect(again!.manifest.version, 'v1');
    expect(bundle.loads, loadsAfterFirst, reason: '版本相同不應再複製');
  });

  test('App 更新換了模型版本時重新解出並刪除舊版', () async {
    final svc = ModelService(dir.path);
    await svc.ensureBundled(FakeBundle(bundleFor('v1')));
    final m = (await svc.ensureBundled(FakeBundle(bundleFor('v2', bump: 5))))!;
    expect(m.manifest.version, 'v2');
    expect(await File(m.path('image')).length(), 15);
    expect(await Directory('${dir.path}/v1').exists(), isFalse);
  });

  test('解出的檔案不完整時視為未安裝，下次重新解出', () async {
    final svc = ModelService(dir.path);
    final m = (await svc.ensureBundled(FakeBundle(bundleFor('v1'))))!;
    await File(m.path('text')).writeAsBytes([1, 2, 3]);
    expect(await svc.installed(), isNull);
    final fixed = (await svc.ensureBundled(FakeBundle(bundleFor('v1'))))!;
    expect(await File(fixed.path('text')).length(), 20);
  });

  test('安裝檔未內建模型時回傳 null', () async {
    expect(await ModelService(dir.path).ensureBundled(FakeBundle({})), isNull);
  });

  test('內建檔案大小與 manifest 不符時報錯', () async {
    final files = bundleFor('v1');
    files['$kBundledModelDir/text'] = [1];
    expect(
      () => ModelService(dir.path).ensureBundled(FakeBundle(files)),
      throwsStateError,
    );
  });
}
