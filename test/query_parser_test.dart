import 'package:flutter_test/flutter_test.dart';
import 'package:photo_prompt/services/query_parser.dart';

void main() {
  // 固定「現在」為 2026-11-10（週二）。
  final parser = QueryParser(clock: () => DateTime(2026, 11, 10, 15));

  test('日期 + 地點 + 類型 + 語意', () {
    final q = parser.parse('去年在日本拍的海邊影片');
    expect(q.from, DateTime(2025));
    expect(q.to, DateTime(2026));
    expect(q.place?.name, '日本');
    expect(q.kind, MediaKind.video);
    expect(q.semantic, '海邊');
  });

  test('城市優先於國家', () {
    expect(parser.parse('東京的夜景').place?.name, '東京');
    expect(parser.parse('東京的夜景').semantic, '夜景');
  });

  test('年月', () {
    final q = parser.parse('2023年5月 貓');
    expect(q.from, DateTime(2023, 5));
    expect(q.to, DateTime(2023, 6));
    expect(q.semantic, '貓');
  });

  test('完整日期', () {
    final q = parser.parse('2024/12/31 煙火');
    expect(q.from, DateTime(2024, 12, 31));
    expect(q.to, DateTime(2025, 1, 1));
    expect(q.semantic, '煙火');
  });

  test('相對日期', () {
    expect(parser.parse('上個月的照片').from, DateTime(2026, 10));
    expect(parser.parse('上個月的照片').to, DateTime(2026, 11));
    expect(parser.parse('昨天').from, DateTime(2026, 11, 9));
    expect(parser.parse('上週的聚餐').from, DateTime(2026, 11, 2));
    expect(parser.parse('上週的聚餐').to, DateTime(2026, 11, 9));
    expect(parser.parse('三年前的旅行').from, DateTime(2023));
    expect(parser.parse('最近7天').from, DateTime(2026, 11, 3));
  });

  test('一月跨年的上個月', () {
    final p = QueryParser(clock: () => DateTime(2026, 1, 15));
    expect(p.parse('上個月').from, DateTime(2025, 12));
    expect(p.parse('上個月').to, DateTime(2026, 1));
  });

  test('無年份的月份：未到的月份視為去年', () {
    expect(parser.parse('12月的聖誕樹').from, DateTime(2025, 12));
    expect(parser.parse('3月的櫻花').from, DateTime(2026, 3));
  });

  test('季節', () {
    final q = parser.parse('去年夏天的海邊');
    expect(q.from, DateTime(2025, 6));
    expect(q.to, DateTime(2025, 9));
    expect(q.semantic, '海邊');

    final any = parser.parse('冬天的雪景');
    expect(any.from, isNull);
    expect(any.months, {12, 1, 2});
    expect(any.semantic, '雪景');

    final winter = parser.parse('2024年冬天');
    expect(winter.from, DateTime(2024, 12));
    expect(winter.to, DateTime(2025, 3));
  });

  test('中文數字', () {
    expect(QueryParser.parseNumber('二〇二三'), 2023);
    expect(QueryParser.parseNumber('十二'), 12);
    expect(QueryParser.parseNumber('二十'), 20);
    expect(QueryParser.parseNumber('三十一'), 31);
    expect(parser.parse('二〇二三年五月').from, DateTime(2023, 5));
  });

  test('未匹配的部分整段交給語意搜尋', () {
    final q = parser.parse('穿紅色衣服的小孩在公園');
    expect(q.hasFilter, isFalse);
    expect(q.semantic, '穿紅色衣服的小孩在公園');
  });

  test('只有條件時語意為空', () {
    final q = parser.parse('今年的影片');
    expect(q.kind, MediaKind.video);
    expect(q.semantic, isEmpty);
  });

  test('英文關鍵字', () {
    final q = parser.parse('Tokyo videos');
    expect(q.place?.name, '東京');
    expect(q.kind, MediaKind.video);
  });

  test('移除單一條件後組回提示詞，重新解析得到其餘條件', () {
    final q = parser.parse('去年在日本拍的海邊影片「發票」');
    expect(q.toPrompt(), '去年 日本 海邊 影片 「發票」');

    final noPlace = parser.parse(q.without(QueryPart.place).toPrompt());
    expect(noPlace.place, isNull);
    expect(noPlace.from, DateTime(2025));
    expect(noPlace.kind, MediaKind.video);
    expect(noPlace.semantic, '海邊');
    expect(noPlace.textTerms, ['發票']);

    final noDate = parser.parse(q.without(QueryPart.date).toPrompt());
    expect(noDate.from, isNull);
    expect(noDate.place?.name, '日本');

    final noText = q.without(QueryPart.text, term: '發票');
    expect(noText.textTerms, isEmpty);
    expect(
      parser.parse(q.without(QueryPart.semantic).toPrompt()).semantic,
      isEmpty,
    );
    expect(parser.parse('冬天的雪景').without(QueryPart.semantic).toPrompt(), '冬天');
  });

  test('排除條件：不要、沒有、排除、減號', () {
    var q = parser.parse('海邊 不要有人');
    expect(q.semantic, '海邊');
    expect(q.exclude, ['人']);

    q = parser.parse('沒有人的海邊');
    expect(q.semantic, '海邊');
    expect(q.exclude, ['人']);

    q = parser.parse('除了狗以外的寵物');
    expect(q.semantic, '寵物');
    expect(q.exclude, ['狗']);

    q = parser.parse('去年日本 -截圖 排除文字');
    expect(q.exclude, ['截圖', '文字']);
    expect(q.semantic, '');
    expect(q.place?.name, '日本');
    expect(q.from, DateTime(2025));

    // 日期裡的連字號不是排除。
    q = parser.parse('2023-05-03 的照片');
    expect(q.exclude, isEmpty);
    expect(q.from, DateTime(2023, 5, 3));
  });

  test('排除條件可個別移除，並能組回提示詞', () {
    final q = parser.parse('海邊 不要有人 不要車');
    expect(q.toPrompt(), '海邊 不要人 不要車');
    expect(parser.parse(q.toPrompt()).exclude, ['人', '車']);
    final one = q.without(QueryPart.exclude, term: '人');
    expect(one.exclude, ['車']);
    expect(one.semantic, '海邊');
  });
}
