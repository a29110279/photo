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
  });

  final String id;
  final bool isVideo;

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

  static const _version = 1;

  static Future<LocalStore> open(String path, {DatabaseFactory? factory}) async {
    final f = factory ?? databaseFactory;
    final db = await f.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _version,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
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
  model_version TEXT
)''');
          await db.execute('CREATE INDEX idx_assets_state ON assets(index_state, create_ts DESC)');
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
        },
      ),
    );
    return LocalStore(db);
  }

  Future<void> close() => db.close();

  // ---- 設定 ----

  Future<String?> getSetting(String key) async {
    final rows = await db.query('kv', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setSetting(String key, String? value) => db.insert(
        'kv',
        {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  // ---- 媒體同步（增量） ----

  /// 與裝置媒體清單同步：新增、移除已不存在者、修改過的重設為待索引。
  /// 回傳 (新增或變更數, 移除數)。
  Future<(int, int)> syncAssets(List<AssetRecord> current) async {
    final rows = await db.query('assets', columns: ['id', 'modified_ts']);
    final known = {for (final r in rows) r['id'] as String: r['modified_ts'] as int};
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
          },
          where: 'id = ?',
          whereArgs: [a.id],
        );
        batch.delete('embeddings', where: 'asset_id = ?', whereArgs: [a.id]);
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
  Future<List<AssetRecord>> pendingAssets(String modelVersion, {int limit = 50}) async {
    final rows = await db.query(
      'assets',
      where: 'index_state = ? OR (index_state = ? AND model_version IS NOT ?)',
      whereArgs: [IndexState.pending, IndexState.done, modelVersion],
      orderBy: 'create_ts DESC',
      limit: limit,
    );
    return rows.map(_toRecord).toList();
  }

  Future<({int total, int done, int failed})> indexStats(String? modelVersion) async {
    final r = (await db.rawQuery(
      'SELECT COUNT(*) AS total, '
      'SUM(CASE WHEN index_state = 1 AND model_version IS ? THEN 1 ELSE 0 END) AS done, '
      'SUM(CASE WHEN index_state = 2 THEN 1 ELSE 0 END) AS failed FROM assets',
      [modelVersion],
    ))
        .first;
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
  }) async {
    await db.transaction((txn) async {
      await txn.delete('embeddings', where: 'asset_id = ?', whereArgs: [assetId]);
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
          'lng': ?lng,
        },
        where: 'id = ?',
        whereArgs: [assetId],
      );
    });
    _matrix = null;
  }

  Future<void> markFailed(String assetId) => db.update(
        'assets',
        {'index_state': IndexState.failed},
        where: 'id = ?',
        whereArgs: [assetId],
      );

  /// 將失敗或全部項目重設為待索引。
  Future<void> resetIndex({bool onlyFailed = false}) async {
    if (onlyFailed) {
      await db.update('assets', {'index_state': IndexState.pending},
          where: 'index_state = ?', whereArgs: [IndexState.failed]);
    } else {
      await db.delete('embeddings');
      await db.update('assets', {'index_state': IndexState.pending, 'model_version': null});
    }
    _matrix = null;
  }

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
    final m = EmbeddingMatrix(dim, ids, Float32List.sublistView(data, 0, n * dim));
    _matrix = m;
    _matrixVersion = modelVersion;
    return m;
  }

  /// 依 metadata 條件過濾，回傳符合的 asset（新到舊）。
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
    final rows = await db.query(
      'assets',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args,
      orderBy: 'create_ts DESC',
    );
    var list = rows.map(_toRecord);
    final months = q.months;
    if (months != null) {
      list = list.where((a) => months.contains(
          DateTime.fromMillisecondsSinceEpoch(a.createTs * 1000).month));
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
      );

  // ---- 操作日誌 ----

  Future<int> addOpLog({
    required String kind,
    required String albumName,
    String? albumId,
    required List<OpItem> items,
  }) =>
      db.insert('op_log', {
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
}
