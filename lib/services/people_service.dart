import 'dart:isolate';
import 'dart:typed_data';

import '../data/local_store.dart';
import '../data/setting_keys.dart';
import 'face_service.dart';

/// 一位人物（O12）：同一群（或同名的多群）人臉所在的相片。
class Person {
  const Person({
    required this.key,
    required this.faceIds,
    required this.assetIds,
    required this.anchors,
    this.name,
  });

  /// 穩定的識別：有名字用名字，否則用群編號。
  final String key;
  final String? name;
  final List<int> faceIds;

  /// 每個組成群各取一張代表臉，命名時記在這些臉上。
  final List<int> anchors;

  /// 依時間由新到舊。
  final List<String> assetIds;

  String get cover => assetIds.first;
}

/// 人物分群與命名（O12）。
class PeopleService {
  PeopleService(this.store);
  final LocalStore store;

  /// 重新分群（人臉數量有變才重算），結果寫回資料庫供搜尋使用。
  Future<void> recluster({bool force = false}) async {
    final faces = await store.allFaces();
    final stamp = '${faces.length}:${faces.isEmpty ? 0 : faces.last.id}';
    if (!force &&
        stamp == await store.getSetting(SettingKeys.faceClusterStamp) &&
        faces.every((f) => f.cluster != null)) {
      return;
    }
    final vectors = [for (final f in faces) f.vec];
    final labels = await Isolate.run(
      () => clusterFaces(List<Float32List>.of(vectors)),
    );
    await store.saveFaceClusters({
      for (var i = 0; i < faces.length; i++) faces[i].id: labels[i],
    });
    await store.setSetting(SettingKeys.faceClusterStamp, stamp);
  }

  /// 人物清單（至少出現在 [minPhotos] 張相片），依相片數由多到少。
  Future<List<Person>> people({int minPhotos = 3}) async {
    await recluster();
    final faces = await store.allFaces();
    final names = await store.personNames();
    final created = {for (final a in await store.allAssets()) a.id: a.createTs};

    // 先依群組合，群內若有人臉被命名，整群以該名字為準；同名的多群合併。
    final byCluster = <int, List<({int id, String assetId})>>{};
    for (final f in faces) {
      final c = f.cluster;
      if (c == null) continue;
      byCluster.putIfAbsent(c, () => []).add((id: f.id, assetId: f.assetId));
    }
    final groups =
        <
          String,
          ({
            String? name,
            List<int> faceIds,
            List<int> anchors,
            Set<String> assets,
          })
        >{};
    byCluster.forEach((cluster, members) {
      String? name;
      for (final m in members) {
        name ??= names[m.id];
      }
      final key = name ?? 'c$cluster';
      final g = groups.putIfAbsent(
        key,
        () => (
          name: name,
          faceIds: <int>[],
          anchors: <int>[],
          assets: <String>{},
        ),
      );
      g.anchors.add(members.first.id);
      for (final m in members) {
        g.faceIds.add(m.id);
        g.assets.add(m.assetId);
      }
    });

    final out = [
      for (final e in groups.entries)
        if (e.value.assets.length >= minPhotos)
          Person(
            key: e.key,
            name: e.value.name,
            faceIds: e.value.faceIds,
            anchors: e.value.anchors,
            assetIds: e.value.assets.toList()
              ..sort((a, b) => (created[b] ?? 0).compareTo(created[a] ?? 0)),
          ),
    ]..sort((a, b) => b.assetIds.length.compareTo(a.assetIds.length));
    return out;
  }

  /// 為人物命名（空字串表示移除名字）。
  Future<void> rename(Person person, String name) =>
      store.namePerson(person.faceIds, person.anchors, name);
}
