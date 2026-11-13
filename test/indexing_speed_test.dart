import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_prompt/data/local_store.dart';
import 'package:photo_prompt/services/embedding_service.dart';
import 'package:photo_prompt/services/query_parser.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

AssetRecord rec(String id, {bool video = false, double? lat, int ts = 1}) =>
    AssetRecord(
      id: id,
      isVideo: video,
      createTs: ts,
      modifiedTs: 1,
      lat: lat,
      lng: lat,
    );

void main() {
  sqfliteFfiInit();
  late LocalStore store;
  setUp(() async {
    store = await LocalStore.open(
      inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
  });
  tearDown(() => store.close());

  test('推論執行緒候選：不超過核心數', () {
    expect(threadCandidates(8), [2, 4, 6, 8]);
    expect(threadCandidates(6), [2, 4, 6]);
    expect(threadCandidates(4), [2, 4]);
    expect(threadCandidates(1), [1]);
  });

  test('推論設定：差距不到一成時維持原設定，並可存回快取', () {
    expect(clearlyFaster(89, 100), isTrue);
    expect(clearlyFaster(95, 100), isFalse);

    const t = InferenceTuning(threads: 4, xnnpack: true, batch: 4, ms: 51.5);
    expect(t.label, '4 執行緒・XNNPACK・批次 4');
    expect(const InferenceTuning(threads: 2).label, '2 執行緒');
    final back = InferenceTuning.fromJson(t.toJson());
    expect(
      (back.threads, back.xnnpack, back.batch, back.ms),
      (4, true, 4, 51.5),
    );
    // 舊格式的快取只有執行緒數。
    expect(InferenceTuning.fromJson({'threads': 6}).batch, 1);
  });

  group('normalizeRgba', () {
    const spec = PreprocessSpec(2, [0.5, 0.5, 0.5], [0.5, 0.5, 0.5], false);

    test('輸出 NCHW，依 mean/std 正規化', () {
      // 2×2：紅、綠、藍、白
      final rgba = Uint8List.fromList([
        255, 0, 0, 255, 0, 255, 0, 255, //
        0, 0, 255, 255, 255, 255, 255, 255,
      ]);
      final out = normalizeRgba(rgba, 2, 2, spec);
      expect(out.length, 12);
      // R 平面：1, -1, -1, 1
      expect(out.sublist(0, 4), [1, -1, -1, 1]);
      // G 平面：-1, 1, -1, 1
      expect(out.sublist(4, 8), [-1, 1, -1, 1]);
      // B 平面：-1, -1, 1, 1
      expect(out.sublist(8, 12), [-1, -1, 1, 1]);
    });

    test('centerCrop 取中央區域', () {
      const crop = PreprocessSpec(1, [0, 0, 0], [1, 1, 1], true);
      // 3×1：只有中間像素是白色
      final rgba = Uint8List.fromList([
        0, 0, 0, 255, 255, 255, 255, 255, 0, 0, 0, 255, //
      ]);
      expect(normalizeRgba(rgba, 3, 1, crop), [1, 1, 1]);
    });
  });

  group('GPS 延後讀取', () {
    test('列舉時已有座標者不需再讀，其餘待讀；讀過就不再重試', () async {
      await store.syncAssets([
        rec('ios', lat: 25.0, ts: 3),
        rec('a', ts: 2),
        rec('b', ts: 1),
      ]);
      expect((await store.pendingGps()).map((e) => e.id), ['a', 'b']);

      await store.saveLocation('a', 35.6, 139.7);
      await store.saveLocation('b', null, null);
      expect(await store.pendingGps(), isEmpty);

      final inJapan = await store.filterAssets(QueryParser().parse('日本'));
      expect(inJapan.map((e) => e.id), ['a']);
    });

    test('檔案修改後重新讀取 GPS', () async {
      await store.syncAssets([rec('a')]);
      await store.saveLocation('a', null, null);
      await store.syncAssets([
        const AssetRecord(id: 'a', isVideo: false, createTs: 1, modifiedTs: 2),
      ]);
      expect((await store.pendingGps()).single.id, 'a');
    });
  });

  test('背景索引只取相片', () async {
    await store.syncAssets([rec('p', ts: 1), rec('v', video: true, ts: 2)]);
    expect((await store.pendingAssets('m')).map((e) => e.id), ['v', 'p']);
    expect(
      (await store.pendingAssets('m', photosOnly: true)).map((e) => e.id),
      ['p'],
    );
  });
}
