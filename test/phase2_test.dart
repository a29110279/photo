import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_prompt/data/local_store.dart';
import 'package:photo_prompt/services/album_service.dart';
import 'package:photo_prompt/services/duplicate_service.dart';
import 'package:photo_prompt/services/query_parser.dart';
import 'package:photo_prompt/services/search_service.dart';
import 'package:photo_prompt/services/smart_album_service.dart';
import 'package:photo_prompt/services/vector_search.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Float32List vec(List<double> v) => l2Normalize(Float32List.fromList(v));

int ts(int y, [int m = 1, int d = 1, int h = 0]) =>
    DateTime(y, m, d, h).millisecondsSinceEpoch ~/ 1000;

AssetRecord photo(String id, int createTs, {bool video = false}) =>
    AssetRecord(id: id, isVideo: video, createTs: createTs, modifiedTs: 1);

void main() {
  sqfliteFfiInit();
  final parser = QueryParser(clock: () => DateTime(2026, 11, 10));
  late LocalStore store;

  setUp(() async {
    store = await LocalStore.open(
      inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
  });
  tearDown(() => store.close());

  group('O9 OCR', () {
    test('引號內的字詞成為文字條件，其餘照常解析', () {
      final q = parser.parse('去年寫著「發票」的截圖');
      expect(q.textTerms, ['發票']);
      expect(q.from, DateTime(2025));
      expect(q.semantic, '截圖');
      expect(q.hasFilter, isTrue);

      final multi = parser.parse('"Wi-Fi" 「密碼」');
      expect(multi.textTerms, ['Wi-Fi', '密碼']);
      expect(multi.semantic, isEmpty);
    });

    test('引號內的日期、地名不會被當成條件', () {
      final q = parser.parse('「台北2023年」');
      expect(q.textTerms, ['台北2023年']);
      expect(q.from, isNull);
      expect(q.place, isNull);
    });

    test('OCR 文字正規化後可比對（忽略大小寫與空白）', () async {
      await store.syncAssets([
        photo('r', ts(2025)),
        photo('x', ts(2025)),
        photo('v', ts(2025), video: true),
      ]);
      expect((await store.pendingOcr()).map((a) => a.id).toSet(), {'r', 'x'});
      await store.saveOcr('r', '統一 發票\nWi-Fi Password');
      await store.saveOcr('x', '   ');
      expect(await store.pendingOcr(), isEmpty);
      expect(await store.ocrStats(), (total: 2, done: 2));

      Future<List<String>> find(String prompt) async => [
        for (final a in await store.filterAssets(parser.parse(prompt))) a.id,
      ];
      expect(await find('「統一發票」'), ['r']);
      expect(await find('"wifi"'), isEmpty);
      expect(await find('"WI-FI password"'), ['r']);
      expect(await find('「發票」「收據」'), isEmpty);
    });

    test('檔案修改後 OCR 需重做', () async {
      await store.syncAssets([photo('r', ts(2025))]);
      await store.saveOcr('r', '發票');
      await store.syncAssets([
        AssetRecord(id: 'r', isVideo: false, createTs: ts(2025), modifiedTs: 2),
      ]);
      expect((await store.pendingOcr()).single.id, 'r');
      expect(await store.filterAssets(parser.parse('「發票」')), isEmpty);
    });
  });

  test('資料庫 v1 → v2 遷移保留資料並新增欄位與資料表', () async {
    final dir = await Directory.systemTemp.createTemp('migrate');
    final path = '${dir.path}/v1.db';
    final v1 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE assets(id TEXT PRIMARY KEY, is_video INTEGER NOT NULL, '
            'create_ts INTEGER NOT NULL, modified_ts INTEGER NOT NULL, duration INTEGER NOT NULL DEFAULT 0, '
            'lat REAL, lng REAL, index_state INTEGER NOT NULL DEFAULT 0, model_version TEXT)',
          );
          await db.execute(
            'CREATE TABLE embeddings(asset_id TEXT NOT NULL, frame INTEGER NOT NULL, '
            'vec BLOB NOT NULL, PRIMARY KEY(asset_id, frame))',
          );
          await db.execute(
            'CREATE TABLE op_log(id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, '
            'kind TEXT NOT NULL, album_name TEXT NOT NULL, album_id TEXT, items TEXT NOT NULL, '
            'undone INTEGER NOT NULL DEFAULT 0)',
          );
          await db.execute('CREATE TABLE kv(key TEXT PRIMARY KEY, value TEXT)');
          await db.insert('assets', {
            'id': 'a',
            'is_video': 0,
            'create_ts': 1,
            'modified_ts': 1,
          });
        },
      ),
    );
    await v1.close();

    final s = await LocalStore.open(path, factory: databaseFactoryFfi);
    expect((await s.pendingOcr()).single.id, 'a');
    expect(await s.createSmartAlbum('n', 'p', 0.2), 1);
    await s.close();
    await dir.delete(recursive: true);
  });

  group('O6 相似分群', () {
    test('時間窗內相似者成群，傳遞相連，時間窗外不比對', () {
      final groups = similarGroups(
        [
          vec([1, 0]),
          vec([1, 0.05]),
          vec([1, 0.1]),
          vec([0, 1]),
          vec([1, 0]),
        ],
        [0, 10, 20, 30, 999999],
        threshold: 0.99,
        windowSeconds: 3600,
      );
      expect(groups, [
        [0, 1, 2],
      ]);
      final all = similarGroups(
        [
          vec([1, 0]),
          vec([0, 1]),
          vec([1, 0]),
        ],
        [0, 1, 999999],
        windowSeconds: null,
      );
      expect(all, [
        [0, 2],
      ]);
    });

    test('DuplicateService 只比對相片並回傳 id', () async {
      await store.syncAssets([
        photo('a', ts(2025, 1, 1, 10)),
        photo('b', ts(2025, 1, 1, 11)),
        photo('c', ts(2025, 1, 1, 12)),
        photo('v', ts(2025, 1, 1, 10), video: true),
      ]);
      await store.saveEmbeddings('a', [
        vec([1, 0]),
      ], 'm');
      await store.saveEmbeddings('b', [
        vec([1, 0.01]),
      ], 'm');
      await store.saveEmbeddings('c', [
        vec([0, 1]),
      ], 'm');
      await store.saveEmbeddings('v', [
        vec([1, 0]),
      ], 'm');
      final groups = await DuplicateService(store)
          .findGroups(modelVersion: 'm', dim: 2);
      expect(groups, [
        ['a', 'b'],
      ]);
      await store.removeAssets(['b']);
      expect(
        await DuplicateService(store).findGroups(modelVersion: 'm', dim: 2),
        isEmpty,
      );
    });
  });

  group('O7 / O8', () {
    Future<Float32List?> embed(String t) async => vec([1, 0, 0]);

    setUp(() async {
      await store.syncAssets([
        photo('q', ts(2025)),
        photo('near', ts(2025)),
        photo('cat', ts(2025)),
        photo('dog', ts(2025)),
      ]);
      await store.saveEmbeddings('q', [
        vec([0, 1, 0]),
      ], 'm');
      await store.saveEmbeddings('near', [
        vec([0.1, 1, 0]),
      ], 'm');
      // 影片多幀取平均
      await store.saveEmbeddings('cat', [
        vec([1, 0.3, 0]),
        vec([1, 0.4, 0]),
      ], 'm');
      await store.saveEmbeddings('dog', [
        vec([1, 0, 0.4]),
      ], 'm');
    });

    test('assetVector 為多幀平均', () async {
      final v = (await store.assetVector('cat', 'm', 3))!;
      final expected = meanVector([
        vec([1, 0.3, 0]),
        vec([1, 0.4, 0]),
      ])!;
      for (var i = 0; i < 3; i++) {
        expect(v[i], closeTo(expected[i], 1e-6));
      }
      expect(await store.assetVector('none', 'm', 3), isNull);
      expect(await store.assetVector('cat', 'other', 3), isNull);
    });

    test('以圖搜圖排除自己，最相似者在前', () async {
      final r = await SearchService(
        store,
        parser: parser,
      ).searchByImage('q', modelVersion: 'm', dim: 3);
      expect(r.byImage, isTrue);
      expect(r.hits.first.asset.id, 'near');
      expect(r.hits.any((h) => h.asset.id == 'q'), isFalse);
    });

    test('Rocchio：選 dog 不選 cat 後，dog 排到 cat 前面', () async {
      final svc = SearchService(store, parser: parser);
      final r = await svc.search(
        '動物',
        embedText: embed,
        modelVersion: 'm',
        dim: 3,
      );
      final order = r.hits.map((h) => h.asset.id).toList();
      expect(order.indexOf('cat'), lessThan(order.indexOf('dog')));

      final refined = await svc.refine(
        r,
        positives: {'dog'},
        negatives: {'cat'},
        modelVersion: 'm',
        dim: 3,
      );
      final order2 = refined.hits.map((h) => h.asset.id).toList();
      expect(order2.indexOf('dog'), lessThan(order2.indexOf('cat')));
      expect(refined.refined, isTrue);
    });

    test('rocchio 結果為單位向量', () {
      final v = rocchio(
        vec([1, 0]),
        [
          vec([0, 1]),
        ],
        [
          vec([1, 1]),
        ],
      );
      expect(v[0] * v[0] + v[1] * v[1], closeTo(1, 1e-6));
    });
  });

  group('O5 智慧相簿', () {
    test('待加入清單排除已處理項目，規則可刪除', () async {
      await store.syncAssets([
        photo('a', ts(2025, 7)),
        photo('b', ts(2025, 8)),
        photo('c', ts(2024)),
      ]);
      final id = await store.createSmartAlbum('去年', '去年的照片', 0.2);
      final rule = (await store.smartAlbums()).single;
      expect(rule.id, id);
      final svc = SmartAlbumService(
        store,
        SearchService(store, parser: parser),
        AlbumService(store),
      );

      expect((await svc.pending(rule)).toSet(), {'a', 'b'});
      // apply 只傳 skipped（不呼叫平台 API），驗證略過的項目不再提示。
      expect(await svc.apply(rule, const [], skipped: ['a']), isNull);
      expect(await svc.pending(rule), ['b']);

      // 新項目出現後會被列入。
      await store.syncAssets([
        photo('a', ts(2025, 7)),
        photo('b', ts(2025, 8)),
        photo('d', ts(2025, 9)),
      ]);
      expect((await svc.pending(rule)).toSet(), {'b', 'd'});

      await store.deleteSmartAlbum(id);
      expect(await store.smartAlbums(), isEmpty);
      expect(await store.smartAlbumProcessed(id), isEmpty);
    });
  });
}
