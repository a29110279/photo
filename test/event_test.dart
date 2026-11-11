import 'package:flutter_test/flutter_test.dart';
import 'package:photo_prompt/data/local_store.dart';
import 'package:photo_prompt/services/event_service.dart';

int t(int d, int h, [int m = 0]) =>
    DateTime(2025, 7, d, h, m).millisecondsSinceEpoch ~/ 1000;

AssetRecord a(String id, int ts, {double? lat, double? lng}) => AssetRecord(
  id: id,
  isVideo: false,
  createTs: ts,
  modifiedTs: 1,
  lat: lat,
  lng: lng,
);

List<AssetRecord> burst(
  String p,
  int d,
  int h,
  int n, {
  double? lat,
  double? lng,
}) => [
  for (var i = 0; i < n; i++) a('$p$i', t(d, h, i * 10), lat: lat, lng: lng),
];

void main() {
  test('時間相隔過久就切成新事件，太小的事件不保留，新到舊排列', () {
    final events = clusterEvents([
      ...burst('x', 1, 9, 6),
      ...burst('y', 1, 20, 6), // 相隔 > 4 小時
      ...burst('z', 3, 9, 2), // 只有 2 張
    ]);
    expect(events.length, 2);
    expect(events.first.assetIds.first, 'y0');
    expect(events.last.assetIds.length, 6);
  });

  test('時間連續但地點相距很遠時切開，並以多數座標命名地點', () {
    final events = clusterEvents([
      ...burst('t', 5, 9, 6, lat: 35.68, lng: 139.76), // 東京
      ...burst('o', 5, 10, 6, lat: 34.69, lng: 135.50), // 大阪，約 400 公里
    ]);
    expect(events.map((e) => e.place), ['大阪', '東京']);
    expect(events.last.title, '2025/07/05 東京');
    expect(events.last.suggestedAlbumName, '2025-07 東京');
  });

  test('跨日事件的標題與沒有座標時的名稱', () {
    final e = clusterEvents([
      for (var i = 0; i < 6; i++) a('n$i', t(1, 22) + i * 3600),
    ]).single;
    expect(e.title, '2025/07/01–07/02');
    expect(e.place, isNull);
    expect(e.suggestedAlbumName, '2025-07 事件');
  });

  test('距離與地名查詢', () {
    expect(distanceKm(25.03, 121.56, 25.03, 121.56), 0);
    expect(distanceKm(35.68, 139.76, 34.69, 135.50), closeTo(400, 20));
    expect(placeOf(35.68, 139.76), '東京');
    expect(placeOf(0, 0), isNull);
  });
}
