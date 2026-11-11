import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_prompt/data/local_store.dart';
import 'package:photo_prompt/data/media_repository.dart';
import 'package:photo_prompt/services/embedding_service.dart';
import 'package:photo_prompt/services/indexing_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 可控制指紋與列舉結果的假媒體庫，並記錄完整列舉的次數。
class FakeMedia extends MediaRepository {
  FakeMedia(this.records, this.sig);
  List<AssetRecord> records;
  String sig;
  int fullScans = 0;

  @override
  Future<String> signature() async => sig;

  @override
  Future<List<AssetRecord>> allRecords() async {
    fullScans++;
    return records;
  }
}

AssetRecord rec(String id, {int ts = 1, bool shot = false, int mod = 1}) =>
    AssetRecord(
      id: id,
      isVideo: false,
      createTs: ts,
      modifiedTs: mod,
      screenshot: shot,
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

  group('媒體庫指紋', () {
    test('指紋沒變就略過完整列舉，變了才重新列舉', () async {
      final media = FakeMedia([rec('a')], 's1');
      final svc = IndexingService(store, media);
      await svc.sync();
      await svc.sync();
      expect(media.fullScans, 1);
      expect((await store.indexStats(null)).total, 1);

      media
        ..records = [rec('a'), rec('b')]
        ..sig = 's2';
      await svc.sync();
      expect(media.fullScans, 2);
      expect((await store.indexStats(null)).total, 2);

      await svc.sync(force: true);
      expect(media.fullScans, 3);
    });
  });

  group('O10 整理', () {
    test('截圖旗標：新增時寫入，舊資料同步時補上', () async {
      await store.syncAssets([rec('a', ts: 2, shot: true), rec('b')]);
      expect((await store.screenshots()).map((e) => e.id), ['a']);
      // 模擬升級：同一張相片後來被判定為截圖，修改時間未變。
      await store.syncAssets([
        rec('a', ts: 2, shot: true),
        rec('b', shot: true),
      ]);
      expect((await store.screenshots()).map((e) => e.id), ['a', 'b']);
    });

    test('最模糊的相片排在前面，排除截圖與無法計算者', () async {
      await store.syncAssets([
        rec('sharp'),
        rec('blur'),
        rec('shot', shot: true),
        rec('bad'),
        rec('pending'),
      ]);
      await store.saveSharpness('sharp', 900);
      await store.saveSharpness('blur', 12);
      await store.saveSharpness('shot', 1);
      await store.saveSharpness('bad', null);
      expect((await store.blurriest()).map((e) => e.id), ['blur', 'sharp']);
    });

    test('待補算清晰度：只取已索引、尚未計算的相片', () async {
      await store.syncAssets([rec('done'), rec('new'), rec('calc')]);
      await store.saveEmbeddings('done', [Float32List(2)], 'm');
      await store.saveEmbeddings('calc', [Float32List(2)], 'm', sharpness: 5);
      expect((await store.pendingSharpness()).map((e) => e.id), ['done']);
    });

    test('Laplacian 變異數：平坦影像為 0，有邊緣時較大', () {
      Uint8List image(int Function(int x, int y) v) {
        final out = Uint8List(8 * 8 * 4);
        for (var y = 0; y < 8; y++) {
          for (var x = 0; x < 8; x++) {
            final p = (y * 8 + x) * 4;
            out[p] = out[p + 1] = out[p + 2] = v(x, y);
            out[p + 3] = 255;
          }
        }
        return out;
      }

      expect(laplacianVariance(image((_, _) => 128), 8, 8), 0);
      final edges = laplacianVariance(
        image((x, _) => x.isEven ? 0 : 255),
        8,
        8,
      );
      final soft = laplacianVariance(image((x, _) => x * 30), 8, 8);
      expect(edges, greaterThan(soft));
    });
  });
}
