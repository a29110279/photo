import 'dart:io';

import 'package:photo_manager/photo_manager.dart';

import '../data/local_store.dart';

class AlbumResult {
  const AlbumResult({required this.logId, required this.count, required this.moved});
  final int logId;
  final int count;

  /// true = Android 實際搬移檔案；false = iOS 加入相簿（原檔不動）。
  final bool moved;
}

/// 相簿操作（C9/C10）與操作日誌、復原（O1）。
///
/// - iOS：建立相簿並「加入」，原檔位置不變。
/// - Android 11+：以 MediaStore.createWriteRequest 批次授權後更新
///   RELATIVE_PATH，檔案實際搬到 `Pictures/<相簿名>/`。
class AlbumService {
  AlbumService(this.store);
  final LocalStore store;

  static bool get movesFiles => Platform.isAndroid;

  /// Android 相簿對應的資料夾。
  static String androidPath(String albumName) => 'Pictures/$albumName/';

  /// 相簿名稱檢查：不可為空，且不得含路徑字元。
  static String? validateName(String name) {
    final n = name.trim();
    if (n.isEmpty) return '請輸入相簿名稱';
    if (RegExp(r'[\\/:*?"<>|]').hasMatch(n) || n.startsWith('.')) {
      return '相簿名稱含有不允許的字元';
    }
    return null;
  }

  Future<List<AssetPathEntity>> albums() =>
      PhotoManager.getAssetPathList(type: RequestType.common);

  Future<AlbumResult> addToAlbum(String albumName, List<String> assetIds) async {
    final name = albumName.trim();
    final entities = <AssetEntity>[];
    for (final id in assetIds) {
      final e = await AssetEntity.fromId(id);
      if (e != null) entities.add(e);
    }
    if (entities.isEmpty) throw StateError('找不到選取的項目');
    return Platform.isAndroid ? _moveAndroid(name, entities) : _addDarwin(name, entities);
  }

  Future<AlbumResult> _moveAndroid(String name, List<AssetEntity> entities) async {
    final target = androidPath(name);
    final items = <OpItem>[];
    final toMove = <AssetEntity>[];
    for (final e in entities) {
      final from = e.relativePath;
      if (from == target) continue; // 已在目標資料夾
      items.add(OpItem(e.id, from));
      toMove.add(e);
    }
    if (toMove.isEmpty) throw StateError('選取的項目都已在此相簿');
    // 先寫日誌再搬移：即使 App 在搬移途中被終止，仍保有原始位置可復原。
    final logId = await store.addOpLog(kind: 'move', albumName: name, items: items);
    final ok = await PhotoManager.editor.android
        .moveAssetsToPath(entities: toMove, targetPath: target);
    if (!ok) {
      await store.markUndone(logId);
      throw StateError('搬移未完成（可能已取消系統授權）');
    }
    return AlbumResult(logId: logId, count: toMove.length, moved: true);
  }

  Future<AlbumResult> _addDarwin(String name, List<AssetEntity> entities) async {
    AssetPathEntity? album;
    for (final p in await albums()) {
      if (!p.isAll && p.name == name && p.albumType == 1) {
        album = p;
        break;
      }
    }
    album ??= await PhotoManager.editor.darwin.createAlbum(name);
    if (album == null) throw StateError('無法建立相簿');
    final added = <OpItem>[];
    for (final e in entities) {
      try {
        await PhotoManager.editor.copyAssetToPath(asset: e, pathEntity: album);
        added.add(OpItem(e.id, null));
      } on Object {
        // 單張失敗（例如已在相簿中）不中斷整批。
      }
    }
    if (added.isEmpty) throw StateError('沒有項目被加入相簿');
    final logId = await store.addOpLog(
        kind: 'add', albumName: name, albumId: album.id, items: added);
    return AlbumResult(logId: logId, count: added.length, moved: false);
  }

  /// 復原一筆操作：Android 搬回原資料夾；iOS 從相簿移除（不刪除原檔）。
  Future<void> undo(int logId) async {
    final log = await store.opLog(logId);
    if (log == null || log.undone) return;

    if (log.kind == 'move') {
      // 依原始資料夾分組；每組需一次系統授權。
      final groups = <String, List<AssetEntity>>{};
      for (final item in log.items) {
        final from = item.from;
        if (from == null) continue;
        final e = await AssetEntity.fromId(item.assetId);
        if (e != null) groups.putIfAbsent(from, () => []).add(e);
      }
      for (final g in groups.entries) {
        final ok = await PhotoManager.editor.android
            .moveAssetsToPath(entities: g.value, targetPath: g.key);
        if (!ok) throw StateError('復原未完成（可能已取消系統授權）');
      }
    } else {
      final AssetPathEntity album;
      try {
        album = await AssetPathEntity.fromId(log.albumId!);
      } on Object {
        throw StateError('找不到相簿，無法復原');
      }
      final list = <AssetEntity>[];
      for (final item in log.items) {
        final e = await AssetEntity.fromId(item.assetId);
        if (e != null) list.add(e);
      }
      if (list.isNotEmpty) {
        final ok = await PhotoManager.editor.darwin.removeAssetsInAlbum(list, album);
        if (!ok) throw StateError('復原失敗');
      }
    }
    await store.markUndone(logId);
  }
}
