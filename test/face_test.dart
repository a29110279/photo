import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_prompt/data/local_store.dart';
import 'package:photo_prompt/services/face_service.dart';
import 'package:photo_prompt/services/people_service.dart';
import 'package:photo_prompt/services/query_parser.dart';
import 'package:photo_prompt/services/search_service.dart';
import 'package:photo_prompt/services/vector_search.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Float32List vec(List<double> v) => l2Normalize(Float32List.fromList(v));

AssetRecord rec(String id, int ts) =>
    AssetRecord(id: id, isVideo: false, createTs: ts, modifiedTs: 1);

void main() {
  sqfliteFfiInit();

  group('cropFace', () {
    test('裁出人臉區域並縮放、正規化', () {
      // 4×4：左上 2×2 白色，其餘黑色
      final rgba = Uint8List(4 * 4 * 4);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          final v = x < 2 && y < 2 ? 255 : 0;
          final p = (y * 4 + x) * 4;
          rgba[p] = rgba[p + 1] = rgba[p + 2] = v;
          rgba[p + 3] = 255;
        }
      }
      final out = cropFace(
        rgba,
        4,
        4,
        const FaceBox(0, 0, 0.5, 0.5),
        size: 2,
        mean: 0,
        scale: 255,
        margin: 0,
      );
      expect(out.length, 12);
      expect(out.every((v) => (v - 1).abs() < 1e-6), isTrue);
    });

    test('人臉框編碼與解碼', () {
      final b = FaceBox.decode(const FaceBox(0.1, 0.2, 0.3, 0.4).encode());
      expect([b.left, b.top, b.width, b.height], [0.1, 0.2, 0.3, 0.4]);
    });
  });

  test('clusterFaces：相似者同群，不相似者另成一群', () {
    final labels = clusterFaces([
      vec([1, 0, 0]),
      vec([0.95, 0.1, 0]),
      vec([0, 1, 0]),
      vec([0.9, 0, 0.1]),
      vec([0, 0.95, 0.1]),
    ]);
    expect(labels[0], labels[1]);
    expect(labels[0], labels[3]);
    expect(labels[2], labels[4]);
    expect(labels[0], isNot(labels[2]));
  });

  group('人物', () {
    late LocalStore store;
    late PeopleService people;
    setUp(() async {
      store = await LocalStore.open(
        inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      people = PeopleService(store);
      await store.syncAssets([
        for (var i = 0; i < 4; i++) rec('a$i', 10 + i),
        for (var i = 0; i < 3; i++) rec('b$i', 20 + i),
        rec('c0', 30),
      ]);
      Future<void> face(String asset, List<double> v) =>
          store.saveFaces(asset, [(box: '0,0,1,1', vec: vec(v))]);
      for (var i = 0; i < 4; i++) {
        await face('a$i', [1, 0.01 * i, 0]);
      }
      for (var i = 0; i < 3; i++) {
        await face('b$i', [0, 1, 0.01 * i]);
      }
      await face('c0', [0, 0, 1]); // 只出現一次
    });
    tearDown(() => store.close());

    test('分群、依相片數排序，只顯示出現 3 張以上的人物', () async {
      final list = await people.people();
      expect(list.map((p) => p.assetIds.length), [4, 3]);
      expect(list.first.assetIds.first, 'a3', reason: '新到舊');
      expect(list.first.name, isNull);
      expect((await store.pendingFaces()), isEmpty);
    });

    test('命名後可搜尋；同名即合併；清空取消命名', () async {
      var list = await people.people();
      await people.rename(list[0], '小明');
      final search = SearchService(store, parser: QueryParser());
      var r = await search.search('小明');
      expect(r.query.person, '小明');
      expect(r.hits.length, 4);

      list = await people.people();
      final other = list.firstWhere((p) => p.name == null);
      await people.rename(other, '小明');
      list = await people.people();
      expect(list.single.name, '小明');
      expect(list.single.assetIds.length, 7);
      r = await search.search('小明');
      expect(r.hits.length, 7);

      await people.rename(list.single, '');
      list = await people.people();
      expect(list.every((p) => p.name == null), isTrue);
      expect((await search.search('小明')).query.person, isNull);
    });

    test('相片修改後人臉需重新偵測', () async {
      await store.syncAssets([
        for (var i = 0; i < 4; i++)
          AssetRecord(
            id: 'a$i',
            isVideo: false,
            createTs: 10 + i,
            modifiedTs: i == 0 ? 2 : 1,
          ),
        for (var i = 0; i < 3; i++) rec('b$i', 20 + i),
        rec('c0', 30),
      ]);
      expect((await store.pendingFaces()).map((a) => a.id), ['a0']);
      expect((await store.faceStats()).faces, 7);
    });
  });
}
