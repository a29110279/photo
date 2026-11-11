import 'dart:math' as math;

import '../data/local_store.dart';
import 'gazetteer.dart';

/// 一次事件（O11）：時間相近、地點相近的一組相片與影片。
class PhotoEvent {
  const PhotoEvent({
    required this.start,
    required this.end,
    required this.assetIds,
    this.place,
  });

  final DateTime start;
  final DateTime end;

  /// 依時間排序。
  final List<String> assetIds;

  /// 最多項目所在的地點（由內建地名表推得）。
  final String? place;

  String get title {
    String d(DateTime t) =>
        '${t.year}/${t.month.toString().padLeft(2, '0')}/${t.day.toString().padLeft(2, '0')}';
    final sameDay =
        start.year == end.year &&
        start.month == end.month &&
        start.day == end.day;
    final dates = sameDay ? d(start) : '${d(start)}–${d(end).substring(5)}';
    return place == null ? dates : '$dates $place';
  }

  /// 建立相簿時的預設名稱（不含 / 等不允許的字元）。
  String get suggestedAlbumName {
    final m = '${start.year}-${start.month.toString().padLeft(2, '0')}';
    return place == null ? '$m 事件' : '$m $place';
  }
}

/// 兩點距離（公里，haversine）。
double distanceKm(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLng = rad(lng2 - lng1);
  final a =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(lat1)) *
          math.cos(rad(lat2)) *
          math.pow(math.sin(dLng / 2), 2);
  return 2 * r * math.asin(math.sqrt(a));
}

/// 座標所在的最具體地名（地名表依具體程度排序）。
String? placeOf(double lat, double lng) {
  for (final p in kPlaces) {
    if (p.box.contains(lat, lng)) return p.name;
  }
  return null;
}

/// 依時間與 GPS 將項目分群（O11）。
///
/// 相鄰兩項相隔超過 [gap]，或兩者都有座標且相距超過 [maxKm]，就切成新事件。
/// 只保留至少 [minSize] 項的事件，結果由新到舊排列。
List<PhotoEvent> clusterEvents(
  List<AssetRecord> assets, {
  Duration gap = const Duration(hours: 4),
  double maxKm = 30,
  int minSize = 5,
}) {
  final sorted = [...assets]..sort((a, b) => a.createTs.compareTo(b.createTs));
  final groups = <List<AssetRecord>>[];
  AssetRecord? prev;
  AssetRecord? lastWithGps;
  for (final a in sorted) {
    var split = prev == null || a.createTs - prev.createTs > gap.inSeconds;
    if (!split && a.lat != null && lastWithGps != null) {
      split =
          distanceKm(a.lat!, a.lng!, lastWithGps.lat!, lastWithGps.lng!) >
          maxKm;
    }
    if (split) {
      groups.add([]);
      lastWithGps = null;
    }
    groups.last.add(a);
    if (a.lat != null) lastWithGps = a;
    prev = a;
  }

  DateTime t(int s) => DateTime.fromMillisecondsSinceEpoch(s * 1000);
  final events = <PhotoEvent>[
    for (final g in groups)
      if (g.length >= minSize)
        PhotoEvent(
          start: t(g.first.createTs),
          end: t(g.last.createTs),
          assetIds: [for (final a in g) a.id],
          place: _dominantPlace(g),
        ),
  ];
  return events.reversed.toList();
}

String? _dominantPlace(List<AssetRecord> group) {
  final counts = <String, int>{};
  for (final a in group) {
    if (a.lat == null) continue;
    final p = placeOf(a.lat!, a.lng!);
    if (p != null) counts[p] = (counts[p] ?? 0) + 1;
  }
  if (counts.isEmpty) return null;
  return counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
}
