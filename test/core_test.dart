import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_prompt/data/local_store.dart';
import 'package:photo_prompt/services/album_service.dart';
import 'package:photo_prompt/services/bert_tokenizer.dart';
import 'package:photo_prompt/services/model_service.dart';
import 'package:photo_prompt/services/query_parser.dart';
import 'package:photo_prompt/services/search_service.dart';
import 'package:photo_prompt/services/vector_search.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Float32List vec(List<double> v) => l2Normalize(Float32List.fromList(v));

int ts(int y, [int m = 1, int d = 1]) =>
    DateTime(y, m, d).millisecondsSinceEpoch ~/ 1000;

void main() {
  sqfliteFfiInit();
  late LocalStore store;

  setUp(() async {
    store = await LocalStore.open(inMemoryDatabasePath, factory: databaseFactoryFfi);
  });
  tearDown(() => store.close());

  group('BertTokenizer', () {
    final tok = BertTokenizer.fromVocabText(
        ['[PAD]', '[UNK]', '[CLS]', '[SEP]', '海', '邊', 'cat', '##s', ','].join('\n'));

    test('中文逐字、英文 WordPiece、補齊長度', () {
      expect(tok.encode('海邊 Cats, 山', contextLength: 10),
          [2, 4, 5, 6, 7, 8, 1, 3, 0, 0]);
    });

    test('過長時截斷並保留 [SEP]', () {
      final ids = tok.encode('海邊海邊海邊', contextLength: 4);
      expect(ids, [2, 4, 5, 3]);
    });
  });

  group('EmbeddingMatrix', () {
    test('多幀取最高分，並可限制候選集', () {
      final m = EmbeddingMatrix(
        2,
        ['a', 'v', 'v'],
        Float32List.fromList([...vec([1, 0]), ...vec([0, 1]), ...vec([1, 1])]),
      );
      final s = m.score(vec([1, 0]));
      expect(s['a'], closeTo(1, 1e-6));
      expect(s['v'], closeTo(0.7071, 1e-3));
      expect(m.score(vec([1, 0]), allow: {'v'}).keys, ['v']);
    });
  });

  group('LocalStore', () {
    test('增量同步：新增、修改重設、移除', () async {
      final a = AssetRecord(id: 'a', isVideo: false, createTs: ts(2025), modifiedTs: 1);
      final b = AssetRecord(id: 'b', isVideo: true, createTs: ts(2024), modifiedTs: 1);
      expect(await store.syncAssets([a, b]), (2, 0));
      await store.saveEmbeddings('a', [vec([1, 0])], 'm1');
      await store.saveEmbeddings('b', [vec([0, 1])], 'm1');
      expect((await store.indexStats('m1')).done, 2);

      // a 被修改 → 重新待索引；b 被刪除。
      final a2 = AssetRecord(id: 'a', isVideo: false, createTs: ts(2025), modifiedTs: 2);
      expect(await store.syncAssets([a2]), (1, 1));
      final stats = await store.indexStats('m1');
      expect((stats.total, stats.done), (1, 0));
      expect((await store.loadMatrix('m1', 2)).rows, 0);
    });

    test('待索引：最近優先、失敗不重試、換模型需重做', () async {
      await store.syncAssets([
        AssetRecord(id: 'old', isVideo: false, createTs: ts(2020), modifiedTs: 1),
        AssetRecord(id: 'new', isVideo: false, createTs: ts(2025), modifiedTs: 1),
        AssetRecord(id: 'bad', isVideo: false, createTs: ts(2026), modifiedTs: 1),
      ]);
      await store.markFailed('bad');
      expect((await store.pendingAssets('m1')).map((e) => e.id), ['new', 'old']);
      await store.saveEmbeddings('new', [vec([1, 0])], 'm1');
      expect((await store.pendingAssets('m1')).map((e) => e.id), ['old']);
      expect((await store.pendingAssets('m2')).map((e) => e.id), ['new', 'old']);
      await store.resetIndex(onlyFailed: true);
      expect((await store.pendingAssets('m1')).first.id, 'bad');
    });

    test('操作日誌與復原標記', () async {
      final id = await store.addOpLog(
        kind: 'move',
        albumName: '旅行',
        items: const [OpItem('a', 'DCIM/Camera/'), OpItem('b', null)],
      );
      final log = (await store.opLogs()).single;
      expect(log.items.first.from, 'DCIM/Camera/');
      expect(log.undone, isFalse);
      await store.markUndone(id);
      expect((await store.opLog(id))!.undone, isTrue);
    });

    test('設定', () async {
      expect(await store.getSetting('k'), isNull);
      await store.setSetting('k', 'v');
      expect(await store.getSetting('k'), 'v');
    });
  });

  group('SearchService', () {
    final parser = QueryParser(clock: () => DateTime(2026, 11, 10));
    // 假的文字編碼器：「海邊」→ [1,0]，其他 → [0,1]。
    Future<Float32List?> embed(String t) async =>
        t.contains('海邊') ? vec([1, 0]) : vec([0, 1]);

    setUp(() async {
      await store.syncAssets([
        // 去年、東京、影片、海邊
        AssetRecord(id: 'jp', isVideo: true, createTs: ts(2025, 7), modifiedTs: 1, lat: 35.68, lng: 139.76),
        // 去年、台北、相片、海邊
        AssetRecord(id: 'tw', isVideo: false, createTs: ts(2025, 8), modifiedTs: 1, lat: 25.03, lng: 121.56),
        // 今年、無 GPS、相片、山
        AssetRecord(id: 'mt', isVideo: false, createTs: ts(2026, 2), modifiedTs: 1),
      ]);
      await store.saveEmbeddings('jp', [vec([0, 1]), vec([1, 0.1])], 'm1');
      await store.saveEmbeddings('tw', [vec([1, 0.5])], 'm1');
      await store.saveEmbeddings('mt', [vec([0, 1])], 'm1');
    });

    test('混合搜尋：metadata 過濾後再語意排序', () async {
      final svc = SearchService(store, parser: parser);
      final r = await svc.search('去年在日本拍的海邊影片',
          embedText: embed, modelVersion: 'm1', dim: 2);
      expect(r.hits.map((h) => h.asset.id), ['jp']);
      expect(r.hits.single.score, closeTo(0.995, 1e-3));
    });

    test('純語意：依分數排序，門檻可過濾', () async {
      final svc = SearchService(store, parser: parser);
      final r = await svc.search('海邊', embedText: embed, modelVersion: 'm1', dim: 2);
      expect(r.hits.map((h) => h.asset.id), ['jp', 'tw', 'mt']);
      expect(r.above(0.5).map((h) => h.asset.id), ['jp', 'tw']);
    });

    test('純 metadata：不需模型，依時間新到舊', () async {
      final svc = SearchService(store, parser: parser);
      final r = await svc.search('去年的照片');
      expect(r.hits.map((h) => h.asset.id), ['tw']);
      expect(r.isSemantic, isFalse);
      expect(r.above(0.9).length, 1);
    });

    test('無模型且無條件時不回傳整個相簿', () async {
      final r = await SearchService(store, parser: parser).search('海邊');
      expect(r.hits, isEmpty);
    });

    test('季節（不限年份）以月份過濾', () async {
      final r = await SearchService(store, parser: parser).search('夏天');
      expect(r.hits.map((h) => h.asset.id).toSet(), {'jp', 'tw'});
    });

    test('排除條件：符合排除內容的項目依同一個門檻剔除', () async {
      final svc = SearchService(store, parser: parser);
      // 「山」→ [0,1]：jp（其中一幀）與 mt 都很像，tw 只有 0.45。
      final r = await svc.search('海邊 不要山', embedText: embed, modelVersion: 'm1', dim: 2);
      expect(r.query.exclude, ['山']);
      expect(r.usesThreshold, isTrue);
      expect(r.above(0.5).map((h) => h.asset.id), ['tw']);
      // 門檻調高後，排除也跟著變寬鬆；jp 的排除分數是 1.0，仍被剔除。
      expect(r.above(0.8).map((h) => h.asset.id), ['tw']);

      // 只有 metadata 條件時也能排除；刪除項目後仍保留排除資訊。
      final meta = await svc.search('去年 不要山', embedText: embed, modelVersion: 'm1', dim: 2);
      expect(meta.isSemantic, isFalse);
      expect(meta.above(0.5).map((h) => h.asset.id), ['tw']);
      expect(meta.withHits(meta.hits).above(0.5).map((h) => h.asset.id), ['tw']);

      // 模型尚未就緒：無法排除，照常回傳。
      final plain = await svc.search('去年 不要山');
      expect(plain.usesThreshold, isFalse);
      expect(plain.hits.map((h) => h.asset.id).toSet(), {'jp', 'tw'});
    });
  });

  test('ModelManifest 解析與必要檔案檢查', () {
    Map<String, dynamic> file() => {'url': 'x', 'sha256': 'AB', 'size': 10};
    final json = {
      'version': 'v1',
      'embeddingDim': 512,
      'imageSize': 224,
      'mean': [0.5, 0.5, 0.5],
      'std': [0.5, 0.5, 0.5],
      'contextLength': 52,
      'files': {'image': file(), 'text': file(), 'vocab': file()},
    };
    final m = ModelManifest.fromJson(json);
    expect(m.totalSize, 30);
    expect(m.files['image']!.sha256, 'ab');
    expect(m.centerCrop, isFalse);
    expect(
      () => ModelManifest.fromJson({...json, 'imageSize': 153036046}),
      throwsFormatException,
    );
    (json['files'] as Map).remove('vocab');
    expect(() => ModelManifest.fromJson(json), throwsFormatException);
  });

  test('相簿名稱驗證', () {
    expect(AlbumService.validateName('  '), isNotNull);
    expect(AlbumService.validateName('../etc'), isNotNull);
    expect(AlbumService.validateName('a/b'), isNotNull);
    expect(AlbumService.validateName('日本旅行 2025'), isNull);
  });
}
