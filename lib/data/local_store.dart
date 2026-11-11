import 'dart:convert';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../services/query_parser.dart';
import '../services/vector_search.dart';

/// 索引狀態。
abstract final class IndexState {
  static const pending = 0;
  static const done = 1;
  static const failed = 2;
}

class AssetRecord {
  const AssetRecord({
    required this.id,
    required this.isVideo,
    required this.createTs,
    required this.modifiedTs,
    this.duration = 0,
    this.lat,
    this.lng,
    this.screenshot = false,
    this.sharpness,
  });

  final String id;
  final bool isVideo;

  /// 截圖或螢幕錄影（O10）。
  final bool screenshot;

  /// 清晰度（Laplacian 變異數，O10）；尚未計算為 null。
  final double? sharpness;

  /// 秒（epoch）。
  final int createTs;
  final int modifiedTs;
  final int duration;
  final double? lat;
  final double? lng;
}

/// 相簿操作日誌的單筆項目：asset 與其原始位置（Android 為 RELATIVE_PATH）。
class OpItem {
  const OpItem(this.assetId, this.from);
  final String assetId;
  final String? from;
}

class OpLogEntry {
  const OpLogEntry({
    required this.id,
    required this.ts,
    required this.kind,
    required this.albumName,
    required this.albumId,
    required this.items,
    required this.undone,
  });

  final int id;
  final DateTime ts;

  /// 'move'（Android 實際搬移）或 'add'（iOS 加入相簿）。
  final String kind;
  final String albumName;
  final String? albumId;
  final List<OpItem> items;
  final bool undone;
}

/// 本地資料庫：metadata、embedding、操作日誌、設定。
class LocalStore {
  LocalStore(this.db);
  final Database db;

  static const _version = 5;

  static Future<LocalStore> open(
    String path, {
    DatabaseFactory? factory,
  }) async {
    final f = factory ?? databaseFactory;
    final db = await f.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _version,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onUpgrade: (db, oldVersion, _) async {
          if (oldVersion < 2) {
            await db.execute(
              'ALTER TABLE assets ADD COLUMN ocr_state INTEGER NOT NULL DEFAULT 0',
            );
            await _createV2Tables(db);
          }
          if (oldVersion < 3) {
            // 已有座標的項目視為已讀取 GPS。
            await db.execute(
              'ALTER TABLE assets ADD COLUMN gps_state INTEGER NOT NULL DEFAULT 0',
            );
            await db.execute(
              'UPDATE assets SET gps_state = 1 WHERE lat IS NOT NULL',
            );
          }
          if (oldVersion < 4) {
            // 截圖旗標由下次媒體同步補上；清晰度由索引管線補算。
            await db.execute(
              'ALTER TABLE assets ADD COLUMN screenshot INTEGER NOT NULL DEFAULT 0',
            );
            await db.execute('ALTER TABLE assets ADD COLUMN sharpness REAL');
          }
          if (oldVersion < 5) {
            await db.execute(
              'ALTER TABLE assets ADD COLUMN face_state INTEGER NOT NULL DEFAULT 0',
            );
            await _createV5Tables(db);
          }
        },
        onCreate: (db, _) async {
          await db.execute('''
CREATE TABLE assets(
  id TEXT PRIMARY KEY,
  is_video INTEGER NOT NULL,
  create_ts INTEGER NOT NULL,
  modified_ts INTEGER NOT NULL,
  duration INTEGER NOT NULL DEFAULT 0,
  lat REAL,
  lng REAL,
  index_state INTEGER NOT NULL DEFAULT 0,
  model_version TEXT,
  ocr_state INTEGER NOT NULL DEFAULT 0,
  gps_state INTEGER NOT NULL DEFAULT 0,
  screenshot INTEGER NOT NULL DEFAULT 0,
  sharpness REAL,
  face_state INTEGER NOT NULL DEFAULT 0
)''');
          await db.execute(
            'CREATE INDEX idx_assets_state ON assets(index_state, create_ts DESC)',
          );
          await db.execute('''
CREATE TABLE embeddings(
  asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
  frame INTEGER NOT NULL,
  vec BLOB NOT NULL,
  PRIMARY KEY(asset_id, frame)
)''');
          await db.execute('''
CREATE TABLE op_log(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts INTEGER NOT NULL,
  kind TEXT NOT NULL,
  album_name TEXT NOT NULL,
  album_id TEXT,
  items TEXT NOT NULL,
  undone INTEGER NOT NULL DEFAULT 0
)''');
          await db.execute('CREATE TABLE kv(key TEXT PRIMARY KEY, value TEXT)');
          await _createV2Tables(db);
          await _createV5Tables(db);
        },
      ),
    );
    return LocalStore(db);
  }

  /// v2：OCR 文字（O9）、智慧相簿（O5）。
  static Future<void> _createV2Tables(Database db) async {
    await db.execute('''
CREATE TABLE ocr(
  asset_id TEXT PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
  text TEXT NOT NULL
)''');
    await db.execute('''
CREATE TABLE smart_albums(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  prompt TEXT NOT NULL,
  threshold REAL NOT NULL,
  created_ts INTEGER NOT NULL
)''');
    await db.execute('''
CREATE TABLE smart_album_items(
  album_id INTEGER NOT NULL REFERENCES smart_albums(id) ON DELETE CASCADE,
  asset_id TEXT NOT NULL,
  PRIMARY KEY(album_id, asset_id)
)''');
  }

  /// v5：人臉（O12）。cluster 為分群結果；people 以人臉 id 記住使用者取的名字，
  /// 重新分群後名字跟著那張臉所在的群走。
  static Future<void> _createV5Tables(Database db) async {
    await db.execute('''
CREATE TABLE faces(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
  box TEXT NOT NULL,
  vec BLOB NOT NULL,
  cluster INTEGER
)''');
    await db.execute('CREATE INDEX idx_faces_asset ON faces(asset_id)');
    await db.execute('''
CREATE TABLE people(
  face_id INTEGER PRIMARY KEY REFERENCES faces(id) ON DELETE CASCADE,
  name TEXT NOT NULL
)''');
  }

  Future<void> close() => db.close();

  // ---- 設定 ----

  Future<String?> getSetting(String key) async {
    final rows = await db.query('kv', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setSetting(String key, String? value) => db.insert('kv', {
    'key': key,
    'value': value,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  // ---- 媒體同步（增量） ----

  /// 與裝置媒體清單同步：新增、移除已不存在者、修改過的重設為待索引。
  /// 回傳 (新增或變更數, 移除數)。
  Future<(int, int)> syncAssets(List<AssetRecord> current) async {
    final rows = await db.query(
      'assets',
      columns: ['id', 'modified_ts', 'screenshot'],
    );
    final known = {
      for (final r in rows) r['id'] as String: r['modified_ts'] as int,
    };
    final shots = {
      for (final r in rows)
        if (r['screenshot'] == 1) r['id'] as String,
    };
    final seen = <String>{};
    var changed = 0;
    final batch = db.batch();
    for (final a in current) {
      seen.add(a.id);
      final prev = known[a.id];
      if (prev == null) {
        changed++;
        batch.insert('assets', {
          'id': a.id,
          'is_video': a.isVideo ? 1 : 0,
          'create_ts': a.createTs,
          'modified_ts': a.modifiedTs,
          'duration': a.duration,
          'lat': a.lat,
          'lng': a.lng,
          // iOS 的座標在列舉時就拿得到；Android 需另外讀 EXIF。
          'gps_state': a.lat == null ? IndexState.pending : IndexState.done,
          'screenshot': a.screenshot ? 1 : 0,
        });
      } else if (prev != a.modifiedTs) {
        changed++;
        batch.update(
          'assets',
          {
            'modified_ts': a.modifiedTs,
            'create_ts': a.createTs,
            'duration': a.duration,
            'index_state': IndexState.pending,
            'ocr_state': IndexState.pending,
            'lat': a.lat,
            'lng': a.lng,
            'gps_state': a.lat == null ? IndexState.pending : IndexState.done,
            'screenshot': a.screenshot ? 1 : 0,
            'sharpness': null,
            'face_state': IndexState.pending,
          },
          where: 'id = ?',
          whereArgs: [a.id],
        );
        batch.delete('embeddings', where: 'asset_id = ?', whereArgs: [a.id]);
        batch.delete('ocr', where: 'asset_id = ?', whereArgs: [a.id]);
        batch.delete('faces', where: 'asset_id = ?', whereArgs: [a.id]);
      } else if (shots.contains(a.id) != a.screenshot) {
        // 舊版資料庫升級後補上截圖旗標。
        batch.update(
          'assets',
          {'screenshot': a.screenshot ? 1 : 0},
          where: 'id = ?',
          whereArgs: [a.id],
        );
      }
    }
    final removed = known.keys.where((id) => !seen.contains(id)).toList();
    for (final id in removed) {
      batch.delete('assets', where: 'id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
    if (changed > 0 || removed.isNotEmpty) _matrix = null;
    return (changed, removed.length);
  }

  // ---- 索引 ----

  /// 待索引清單（最近的優先）。模型版本不同者也視為待索引。
  Future<List<AssetRecord>> pendingAssets(
    String modelVersion, {
    int limit = 50,
    bool photosOnly = false,
  }) async {
    final rows = await db.query(
      'assets',
      where:
          '(index_state = ? OR (index_state = ? AND model_version IS NOT ?))'
          '${photosOnly ? ' AND is_video = 0' : ''}',
      whereArgs: [IndexState.pending, IndexState.done, modelVersion],
      orderBy: 'create_ts DESC',
      limit: limit,
    );
    return rows.map(_toRecord).toList();
  }

  Future<({int total, int done, int failed})> indexStats(
    String? modelVersion,
  ) async {
    final r = (await db.rawQuery(
      'SELECT COUNT(*) AS total, '
      'SUM(CASE WHEN index_state = 1 AND model_version IS ? THEN 1 ELSE 0 END) AS done, '
      'SUM(CASE WHEN index_state = 2 THEN 1 ELSE 0 END) AS failed FROM assets',
      [modelVersion],
    )).first;
    return (
      total: r['total'] as int,
      done: (r['done'] as int?) ?? 0,
      failed: (r['failed'] as int?) ?? 0,
    );
  }

  /// 寫入一個 asset 的 embedding（可多幀），並標記為完成。向量需已正規化。
  Future<void> saveEmbeddings(
    String assetId,
    List<Float32List> vectors,
    String modelVersion, {
    double? lat,
    double? lng,
    double? sharpness,
  }) async {
    await db.transaction((txn) async {
      await txn.delete(
        'embeddings',
        where: 'asset_id = ?',
        whereArgs: [assetId],
      );
      for (var i = 0; i < vectors.length; i++) {
        final v = vectors[i];
        await txn.insert('embeddings', {
          'asset_id': assetId,
          'frame': i,
          'vec': v.buffer.asUint8List(v.offsetInBytes, v.lengthInBytes),
        });
      }
      await txn.update(
        'assets',
        {
          'index_state': IndexState.done,
          'model_version': modelVersion,
          'lat': ?lat,
          'sharpness': ?sharpness,
          'lng': ?lng,
        },
        where: 'id = ?',
        whereArgs: [assetId],
      );
    });
    // 新索引的項目直接附加到快取；重新索引（已在矩陣中）才整個重載。
    final m = _matrix;
    if (m != null &&
        _matrixVersion == modelVersion &&
        vectors.every((v) => v.length == m.dim) &&
        !m.assetIds.contains(assetId)) {
      m.append(assetId, vectors);
    } else {
      _matrix = null;
    }
  }

  Future<int> videoCount() async =>
      Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM assets WHERE is_video = 1'),
      ) ??
      0;

  Future<void> markFailed(String assetId) => db.update(
    'assets',
    {'index_state': IndexState.failed},
    where: 'id = ?',
    whereArgs: [assetId],
  );

  /// 將失敗或全部項目重設為待索引。
  Future<void> resetIndex({bool onlyFailed = false}) async {
    if (onlyFailed) {
      await db.update(
        'assets',
        {'index_state': IndexState.pending},
        where: 'index_state = ?',
        whereArgs: [IndexState.failed],
      );
    } else {
      await db.delete('embeddings');
      await db.update('assets', {
        'index_state': IndexState.pending,
        'model_version': null,
      });
    }
    _matrix = null;
  }

  /// 已從裝置移除（例如移到垃圾桶）的項目，直接自資料庫刪除。
  Future<void> removeAssets(Iterable<String> ids) async {
    final batch = db.batch();
    for (final id in ids) {
      batch.delete('assets', where: 'id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
    _matrix = null;
  }

  // ---- 人臉（O12） ----

  /// 尚未偵測人臉的相片（最近的優先，不含截圖）。
  Future<List<AssetRecord>> pendingFaces({int limit = 50}) async {
    final rows = await db.query(
      'assets',
      where: 'is_video = 0 AND screenshot = 0 AND face_state = ?',
      whereArgs: [IndexState.pending],
      orderBy: 'create_ts DESC',
      limit: limit,
    );
    return rows.map(_toRecord).toList();
  }

  Future<({int total, int done, int faces})> faceStats() async {
    final r = (await db.rawQuery(
      'SELECT COUNT(*) AS total, '
      'SUM(CASE WHEN face_state <> 0 THEN 1 ELSE 0 END) AS done '
      'FROM assets WHERE is_video = 0 AND screenshot = 0',
    )).first;
    final faces =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM faces'),
        ) ??
        0;
    return (
      total: r['total'] as int,
      done: (r['done'] as int?) ?? 0,
      faces: faces,
    );
  }

  /// 寫入一張相片的人臉（可為空），並標記為已偵測。
  Future<void> saveFaces(
    String assetId,
    List<({String box, Float32List vec})> faces, {
    bool failed = false,
  }) async {
    await db.transaction((txn) async {
      await txn.delete('faces', where: 'asset_id = ?', whereArgs: [assetId]);
      for (final f in faces) {
        await txn.insert('faces', {
          'asset_id': assetId,
          'box': f.box,
          'vec': f.vec.buffer.asUint8List(
            f.vec.offsetInBytes,
            f.vec.lengthInBytes,
          ),
        });
      }
      await txn.update(
        'assets',
        {'face_state': failed ? IndexState.failed : IndexState.done},
        where: 'id = ?',
        whereArgs: [assetId],
      );
    });
  }

  /// 全部人臉（依 id 排序，分群結果才穩定）。
  Future<
    List<({int id, String assetId, String box, Float32List vec, int? cluster})>
  >
  allFaces() async {
    final rows = await db.query('faces', orderBy: 'id ASC');
    return [
      for (final r in rows)
        (
          id: r['id'] as int,
          assetId: r['asset_id'] as String,
          box: r['box'] as String,
          vec: Uint8List.fromList(r['vec'] as Uint8List).buffer.asFloat32List(),
          cluster: r['cluster'] as int?,
        ),
    ];
  }

  Future<void> saveFaceClusters(Map<int, int> clusterByFace) async {
    final batch = db.batch();
    clusterByFace.forEach((face, cluster) {
      batch.update(
        'faces',
        {'cluster': cluster},
        where: 'id = ?',
        whereArgs: [face],
      );
    });
    await batch.commit(noResult: true);
  }

  /// 使用者取的名字：人臉 id → 名字。
  Future<Map<int, String>> personNames() async => {
    for (final r in await db.query('people'))
      r['face_id'] as int: r['name'] as String,
  };

  /// 為人物命名：清掉 [faceIds] 原本的名字，再把名字記在 [anchors]
  /// （每群一張代表臉）上；空字串表示移除名字。
  /// 把不同群取相同名字，就等於把它們合併成同一人。
  Future<void> namePerson(
    List<int> faceIds,
    List<int> anchors,
    String name,
  ) async {
    await db.transaction((txn) async {
      for (final id in faceIds) {
        await txn.delete('people', where: 'face_id = ?', whereArgs: [id]);
      }
      if (name.trim().isEmpty) return;
      for (final id in anchors) {
        await txn.insert('people', {
          'face_id': id,
          'name': name.trim(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  /// 所有人物名稱（搜尋時比對用）。
  Future<List<String>> personNameList() async => [
    for (final r in await db.rawQuery('SELECT DISTINCT name FROM people'))
      r['name'] as String,
  ];

  // ---- 整理（O10） ----

  /// 截圖與螢幕錄影（新到舊）。
  Future<List<AssetRecord>> screenshots() async {
    final rows = await db.query(
      'assets',
      where: 'screenshot = 1',
      orderBy: 'create_ts DESC',
    );
    return rows.map(_toRecord).toList();
  }

  /// 清晰度最低的相片（由模糊到清晰），不含截圖。
  Future<List<AssetRecord>> blurriest({int limit = 300}) async {
    final rows = await db.query(
      'assets',
      where: 'is_video = 0 AND screenshot = 0 AND sharpness >= 0',
      orderBy: 'sharpness ASC',
      limit: limit,
    );
    return rows.map(_toRecord).toList();
  }

  /// 已索引但尚未計算清晰度的相片（舊版資料庫升級後）。
  Future<List<AssetRecord>> pendingSharpness({int limit = 100}) async {
    final rows = await db.query(
      'assets',
      where: 'is_video = 0 AND sharpness IS NULL AND index_state <> ?',
      whereArgs: [IndexState.pending],
      orderBy: 'create_ts DESC',
      limit: limit,
    );
    return rows.map(_toRecord).toList();
  }

  /// 寫入清晰度；無法計算時寫入 -1，避免重複嘗試。
  Future<void> saveSharpness(String assetId, double? sharpness) => db.update(
    'assets',
    {'sharpness': sharpness ?? -1},
    where: 'id = ?',
    whereArgs: [assetId],
  );

  // ---- GPS（延後讀取） ----

  /// 尚未讀取 GPS 的項目（最近的優先）。
  Future<List<AssetRecord>> pendingGps({int limit = 100}) async {
    final rows = await db.query(
      'assets',
      where: 'gps_state = ?',
      whereArgs: [IndexState.pending],
      orderBy: 'create_ts DESC',
      limit: limit,
    );
    return rows.map(_toRecord).toList();
  }

  /// 記錄 GPS 讀取結果；沒有座標也標記為已讀取，不再重試。
  Future<void> saveLocation(String assetId, double? lat, double? lng) =>
      db.update(
        'assets',
        {'gps_state': IndexState.done, 'lat': lat, 'lng': lng},
        where: 'id = ?',
        whereArgs: [assetId],
      );

  // ---- OCR（O9） ----

  /// 搜尋用的文字正規化：小寫、去除所有空白。
  static String normalizeText(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'\s+'), '');

  Future<List<AssetRecord>> pendingOcr({int limit = 50}) async {
    final rows = await db.query(
      'assets',
      where: 'is_video = 0 AND ocr_state = ?',
      whereArgs: [IndexState.pending],
      orderBy: 'create_ts DESC',
      limit: limit,
    );
    return rows.map(_toRecord).toList();
  }

  Future<({int total, int done})> ocrStats() async {
    final r = (await db.rawQuery(
      'SELECT COUNT(*) AS total, '
      'SUM(CASE WHEN ocr_state <> 0 THEN 1 ELSE 0 END) AS done '
      'FROM assets WHERE is_video = 0',
    )).first;
    return (total: r['total'] as int, done: (r['done'] as int?) ?? 0);
  }

  /// 寫入 OCR 結果；空字串也記為完成（代表圖中沒有文字）。
  Future<void> saveOcr(String assetId, String text) async {
    await db.transaction((txn) async {
      final t = normalizeText(text);
      if (t.isEmpty) {
        await txn.delete('ocr', where: 'asset_id = ?', whereArgs: [assetId]);
      } else {
        await txn.insert('ocr', {
          'asset_id': assetId,
          'text': t,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await txn.update(
        'assets',
        {'ocr_state': IndexState.done},
        where: 'id = ?',
        whereArgs: [assetId],
      );
    });
  }

  Future<void> markOcrFailed(String assetId) => db.update(
    'assets',
    {'ocr_state': IndexState.failed},
    where: 'id = ?',
    whereArgs: [assetId],
  );

  // ---- 搜尋 ----

  EmbeddingMatrix? _matrix;
  String? _matrixVersion;

  /// 載入（並快取）指定模型版本的全部 embedding。
  Future<EmbeddingMatrix> loadMatrix(String modelVersion, int dim) async {
    final cached = _matrix;
    if (cached != null && _matrixVersion == modelVersion) return cached;
    final rows = await db.rawQuery(
      'SELECT e.asset_id, e.vec FROM embeddings e '
      'JOIN assets a ON a.id = e.asset_id WHERE a.model_version = ?',
      [modelVersion],
    );
    final ids = <String>[];
    final data = Float32List(rows.length * dim);
    var n = 0;
    for (final r in rows) {
      final blob = r['vec'] as Uint8List;
      if (blob.lengthInBytes != dim * 4) continue;
      // BLOB 的 offset 不一定 4-byte 對齊，複製後再轉型。
      final v = Uint8List.fromList(blob).buffer.asFloat32List();
      data.setRange(n * dim, (n + 1) * dim, v);
      ids.add(r['asset_id'] as String);
      n++;
    }
    final m = EmbeddingMatrix(
      dim,
      ids,
      Float32List.sublistView(data, 0, n * dim),
    );
    _matrix = m;
    _matrixVersion = modelVersion;
    return m;
  }

  /// 單一 asset 的代表向量（多幀取平均後正規化）；尚未索引則回傳 null。
  Future<Float32List?> assetVector(
    String assetId,
    String modelVersion,
    int dim,
  ) async {
    final rows = await db.rawQuery(
      'SELECT e.vec FROM embeddings e JOIN assets a ON a.id = e.asset_id '
      'WHERE e.asset_id = ? AND a.model_version = ?',
      [assetId, modelVersion],
    );
    final sum = Float32List(dim);
    var n = 0;
    for (final r in rows) {
      final blob = r['vec'] as Uint8List;
      if (blob.lengthInBytes != dim * 4) continue;
      final v = Uint8List.fromList(blob).buffer.asFloat32List();
      for (var i = 0; i < dim; i++) {
        sum[i] += v[i];
      }
      n++;
    }
    return n == 0 ? null : l2Normalize(sum);
  }

  /// 依 metadata 條件過濾，回傳符合的 asset（新到舊）。
  /// 全部項目（事件分群用，O11）。
  Future<List<AssetRecord>> allAssets() async => (await db.query(
    'assets',
    orderBy: 'create_ts ASC',
  )).map(_toRecord).toList();

  Future<List<AssetRecord>> filterAssets(ParsedQuery q) async {
    final where = <String>[];
    final args = <Object?>[];
    if (q.from != null && q.to != null) {
      where.add('create_ts >= ? AND create_ts < ?');
      args
        ..add(q.from!.millisecondsSinceEpoch ~/ 1000)
        ..add(q.to!.millisecondsSinceEpoch ~/ 1000);
    }
    if (q.kind != null) {
      where.add('is_video = ?');
      args.add(q.kind == MediaKind.video ? 1 : 0);
    }
    final box = q.place?.box;
    if (box != null) {
      where.add('lat BETWEEN ? AND ? AND lng BETWEEN ? AND ?');
      args.addAll([box.minLat, box.maxLat, box.minLng, box.maxLng]);
    }
    final person = q.person;
    if (person != null) {
      // 人物（O12）：與被命名的人臉同一群的所有相片。
      where.add(
        'id IN (SELECT f2.asset_id FROM people p '
        'JOIN faces f1 ON f1.id = p.face_id '
        'JOIN faces f2 ON f2.cluster = f1.cluster WHERE p.name = ?)',
      );
      args.add(person);
    }
    for (final term in q.textTerms) {
      final t = normalizeText(term);
      if (t.isEmpty) continue;
      where.add('id IN (SELECT asset_id FROM ocr WHERE instr(text, ?) > 0)');
      args.add(t);
    }
    final rows = await db.query(
      'assets',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args,
      orderBy: 'create_ts DESC',
    );
    var list = rows.map(_toRecord);
    final months = q.months;
    if (months != null) {
      list = list.where(
        (a) => months.contains(
          DateTime.fromMillisecondsSinceEpoch(a.createTs * 1000).month,
        ),
      );
    }
    return list.toList();
  }

  static AssetRecord _toRecord(Map<String, Object?> r) => AssetRecord(
    id: r['id'] as String,
    isVideo: r['is_video'] == 1,
    createTs: r['create_ts'] as int,
    modifiedTs: r['modified_ts'] as int,
    duration: r['duration'] as int,
    lat: (r['lat'] as num?)?.toDouble(),
    lng: (r['lng'] as num?)?.toDouble(),
    screenshot: r['screenshot'] == 1,
    sharpness: (r['sharpness'] as num?)?.toDouble(),
  );

  // ---- 操作日誌 ----

  Future<int> addOpLog({
    required String kind,
    required String albumName,
    String? albumId,
    required List<OpItem> items,
  }) => db.insert('op_log', {
    'ts': DateTime.now().millisecondsSinceEpoch,
    'kind': kind,
    'album_name': albumName,
    'album_id': albumId,
    'items': jsonEncode([
      for (final i in items) {'id': i.assetId, 'from': i.from},
    ]),
  });

  Future<List<OpLogEntry>> opLogs({int limit = 100}) async {
    final rows = await db.query('op_log', orderBy: 'id DESC', limit: limit);
    return rows.map(_toLog).toList();
  }

  Future<OpLogEntry?> opLog(int id) async {
    final rows = await db.query('op_log', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : _toLog(rows.first);
  }

  Future<void> markUndone(int id) =>
      db.update('op_log', {'undone': 1}, where: 'id = ?', whereArgs: [id]);

  static OpLogEntry _toLog(Map<String, Object?> r) => OpLogEntry(
    id: r['id'] as int,
    ts: DateTime.fromMillisecondsSinceEpoch(r['ts'] as int),
    kind: r['kind'] as String,
    albumName: r['album_name'] as String,
    albumId: r['album_id'] as String?,
    items: [
      for (final m in jsonDecode(r['items'] as String) as List)
        OpItem(m['id'] as String, m['from'] as String?),
    ],
    undone: r['undone'] == 1,
  );

  // ---- 智慧相簿（O5） ----

  Future<int> createSmartAlbum(String name, String prompt, double threshold) =>
      db.insert('smart_albums', {
        'name': name,
        'prompt': prompt,
        'threshold': threshold,
        'created_ts': DateTime.now().millisecondsSinceEpoch,
      });

  Future<List<SmartAlbum>> smartAlbums() async {
    final rows = await db.query('smart_albums', orderBy: 'id DESC');
    return [
      for (final r in rows)
        SmartAlbum(
          id: r['id'] as int,
          name: r['name'] as String,
          prompt: r['prompt'] as String,
          threshold: (r['threshold'] as num).toDouble(),
        ),
    ];
  }

  Future<void> deleteSmartAlbum(int id) =>
      db.delete('smart_albums', where: 'id = ?', whereArgs: [id]);

  /// 已處理（已加入或已略過）的項目，不會再出現在待加入清單。
  Future<Set<String>> smartAlbumProcessed(int albumId) async {
    final rows = await db.query(
      'smart_album_items',
      columns: ['asset_id'],
      where: 'album_id = ?',
      whereArgs: [albumId],
    );
    return {for (final r in rows) r['asset_id'] as String};
  }

  Future<void> markSmartAlbumProcessed(
    int albumId,
    Iterable<String> ids,
  ) async {
    final batch = db.batch();
    for (final id in ids) {
      batch.insert('smart_album_items', {
        'album_id': albumId,
        'asset_id': id,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await batch.commit(noResult: true);
  }
}

/// 智慧相簿規則：提示詞 + 門檻，符合的新項目可一鍵加入相簿。
class SmartAlbum {
  const SmartAlbum({
    required this.id,
    required this.name,
    required this.prompt,
    required this.threshold,
  });

  final int id;
  final String name;
  final String prompt;
  final double threshold;

  // 作為 provider family 的 key，需以內容比較。
  @override
  bool operator ==(Object other) =>
      other is SmartAlbum &&
      other.id == id &&
      other.name == name &&
      other.prompt == prompt &&
      other.threshold == threshold;

  @override
  int get hashCode => Object.hash(id, name, prompt, threshold);
}
