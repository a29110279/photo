import 'gazetteer.dart';

enum MediaKind { image, video }

/// 規則式解析結果：結構化條件 + 剩餘語意查詢。
class ParsedQuery {
  const ParsedQuery({
    required this.raw,
    this.from,
    this.to,
    this.months,
    this.kind,
    this.place,
    this.semantic = '',
    this.dateLabel,
    this.textTerms = const [],
    this.person,
  });

  final String raw;

  /// 日期區間 [from, to)。
  final DateTime? from;
  final DateTime? to;

  /// 月份限制（季節，不限年份）。
  final Set<int>? months;
  final MediaKind? kind;
  final Place? place;

  /// 交給語意模型的文字；空字串表示只用 metadata 過濾。
  final String semantic;
  final String? dateLabel;

  /// 需出現在相片文字中的字詞（O9，以引號標示，例如「發票」）。
  final List<String> textTerms;

  /// 人物名稱（O12），由 SearchService 比對已命名的人物後填入。
  final String? person;

  ParsedQuery withPerson(String name) => ParsedQuery(
    raw: raw,
    from: from,
    to: to,
    months: months,
    kind: kind,
    place: place,
    semantic: semantic,
    dateLabel: dateLabel,
    textTerms: textTerms,
    person: name,
  );

  bool get hasFilter =>
      person != null ||
      from != null ||
      months != null ||
      kind != null ||
      place != null ||
      textTerms.isNotEmpty;
}

class QueryParser {
  QueryParser({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final DateTime Function() _clock;

  static const _digits = {
    '零': 0,
    '〇': 0,
    '一': 1,
    '二': 2,
    '兩': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  static const _num = r'(\d+|[零〇一二兩三四五六七八九十]+)';

  static const _seasons = {
    '春': {3, 4, 5},
    '夏': {6, 7, 8},
    '秋': {9, 10, 11},
    '冬': {12, 1, 2},
  };

  /// 中文或阿拉伯數字 → int。支援「二〇二三」逐位寫法與「二十三」。
  static int? parseNumber(String s) {
    final n = int.tryParse(s);
    if (n != null) return n;
    if (s.isEmpty) return null;
    if (!s.contains('十')) {
      var v = 0;
      for (final c in s.split('')) {
        final d = _digits[c];
        if (d == null) return null;
        v = v * 10 + d;
      }
      return v;
    }
    final parts = s.split('十');
    if (parts.length != 2) return null;
    final tens = parts[0].isEmpty ? 1 : _digits[parts[0]];
    final ones = parts[1].isEmpty ? 0 : _digits[parts[1]];
    if (tens == null || ones == null) return null;
    return tens * 10 + ones;
  }

  ParsedQuery parse(String input) {
    final now = _clock();
    final today = DateTime(now.year, now.month, now.day);
    var text = input.trim();

    // 引號內的字詞視為 OCR 文字條件，先抽出避免被日期、地點規則誤判。
    final textTerms = <String>[];
    final quoteRe = RegExp('「([^」]+)」|『([^』]+)』|"([^"]+)"|“([^”]+)”');
    text = text.replaceAllMapped(quoteRe, (m) {
      final t = (m[1] ?? m[2] ?? m[3] ?? m[4])!.trim();
      if (t.isNotEmpty) textTerms.add(t);
      return ' ';
    });
    if (textTerms.isNotEmpty) {
      text = text
          .replaceAll(RegExp('(上面)?(寫著|寫有|印著|有)?\\s*(的)?(字樣|文字|字)'), ' ')
          .replaceAll(RegExp('(寫著|寫有|印著)'), ' ');
    }
    DateTime? from, to;
    Set<int>? months;
    String? dateLabel;
    MediaKind? kind;
    Place? place;

    /// 嘗試一條日期規則；命中則移除該片段。
    bool take(RegExp re, void Function(RegExpMatch m) apply) {
      final m = re.firstMatch(text);
      if (m == null) return false;
      apply(m);
      dateLabel = m.group(0);
      text = text.replaceRange(m.start, m.end, ' ');
      return true;
    }

    void setRange(DateTime f, DateTime t) {
      from = f;
      to = t;
    }

    int? relYear(String w) => switch (w) {
      '今年' => now.year,
      '去年' => now.year - 1,
      '前年' => now.year - 2,
      _ => null,
    };

    void applySeason(String s, int? year) {
      final ms = _seasons[s]!;
      if (year == null) {
        months = ms;
      } else if (s == '冬') {
        setRange(DateTime(year, 12), DateTime(year + 1, 3));
      } else {
        final first = ms.reduce((a, b) => a < b ? a : b);
        setRange(DateTime(year, first), DateTime(year, first + 3));
      }
    }

    // 規則依「越具體越優先」排列，只取第一個命中的日期。
    final matched =
        // 2023年5月3日 / 2023/5/3 / 2023-05-03
        take(RegExp('$_num\\s*[年/\\-]\\s*$_num\\s*[月/\\-]\\s*$_num\\s*[日號]?'), (
          m,
        ) {
          final y = parseNumber(m[1]!),
              mo = parseNumber(m[2]!),
              d = parseNumber(m[3]!);
          if (y != null && mo != null && d != null) {
            setRange(DateTime(y, mo, d), DateTime(y, mo, d + 1));
          }
        }) ||
        // 去年夏天 / 2023年夏天
        take(RegExp('(今年|去年|前年|$_num\\s*年)\\s*的?\\s*([春夏秋冬])[天季]'), (m) {
          final y = relYear(m[1]!) ?? parseNumber(m[2]!);
          applySeason(m[3]!, y);
        }) ||
        // 去年5月 / 2023年5月
        take(RegExp('(今年|去年|前年|$_num\\s*年)\\s*的?\\s*$_num\\s*月份?'), (m) {
          final y = relYear(m[1]!) ?? parseNumber(m[2]!);
          final mo = parseNumber(m[3]!);
          if (y != null && mo != null) {
            setRange(DateTime(y, mo), DateTime(y, mo + 1));
          }
        }) ||
        take(RegExp('(今年|去年|前年)'), (m) {
          final y = relYear(m[1]!)!;
          setRange(DateTime(y), DateTime(y + 1));
        }) ||
        // 三年前
        take(RegExp('$_num\\s*年前'), (m) {
          final n = parseNumber(m[1]!);
          if (n != null) {
            setRange(DateTime(now.year - n), DateTime(now.year - n + 1));
          }
        }) ||
        // 2023年
        take(RegExp('((?:19|20)\\d{2}|[一二][零〇九][零〇一二三四五六七八九]{2})\\s*年'), (m) {
          final y = parseNumber(m[1]!);
          if (y != null) setRange(DateTime(y), DateTime(y + 1));
        }) ||
        // 最近 / 過去 N 天|週|個月|年
        take(RegExp('(?:最近|近|過去)\\s*$_num\\s*(天|日|週|周|星期|禮拜|個月|月|年)'), (m) {
          final n = parseNumber(m[1]!);
          if (n == null) return;
          final end = today.add(const Duration(days: 1));
          final start = switch (m[2]!) {
            '天' || '日' => today.subtract(Duration(days: n)),
            '個月' || '月' => DateTime(today.year, today.month - n, today.day),
            '年' => DateTime(today.year - n, today.month, today.day),
            _ => today.subtract(Duration(days: 7 * n)),
          };
          setRange(start, end);
        }) ||
        take(RegExp('上個?月'), (m) {
          setRange(
            DateTime(now.year, now.month - 1),
            DateTime(now.year, now.month),
          );
        }) ||
        take(RegExp('(這個?月|本月)'), (m) {
          setRange(
            DateTime(now.year, now.month),
            DateTime(now.year, now.month + 1),
          );
        }) ||
        take(RegExp('上(週|周|星期|禮拜)'), (m) {
          final monday = today.subtract(Duration(days: today.weekday - 1));
          setRange(monday.subtract(const Duration(days: 7)), monday);
        }) ||
        take(RegExp('(這|本)(週|周|星期|禮拜)'), (m) {
          final monday = today.subtract(Duration(days: today.weekday - 1));
          setRange(monday, monday.add(const Duration(days: 7)));
        }) ||
        take(RegExp('(今天|昨天|前天)'), (m) {
          final back = const {'今天': 0, '昨天': 1, '前天': 2}[m[1]!]!;
          final d = today.subtract(Duration(days: back));
          setRange(d, d.add(const Duration(days: 1)));
        }) ||
        // 5月（無年份）：今年該月，若尚未到則視為去年
        take(RegExp('$_num\\s*月份?'), (m) {
          final mo = parseNumber(m[1]!);
          if (mo == null || mo < 1 || mo > 12) return;
          final y = mo > now.month ? now.year - 1 : now.year;
          setRange(DateTime(y, mo), DateTime(y, mo + 1));
        }) ||
        take(RegExp('([春夏秋冬])[天季]'), (m) => applySeason(m[1]!, null));
    if (!matched) dateLabel = null;

    // 媒體類型
    final videoRe = RegExp('(影片|視頻|錄影|短片|videos?)', caseSensitive: false);
    final imageRe = RegExp('(照片|相片|圖片|photos?|images?)', caseSensitive: false);
    if (videoRe.hasMatch(text)) {
      kind = MediaKind.video;
      text = text.replaceAll(videoRe, ' ');
    } else if (imageRe.hasMatch(text)) {
      kind = MediaKind.image;
      text = text.replaceAll(imageRe, ' ');
    }

    // 地點（地名表中較具體者優先）
    final lower = text.toLowerCase();
    outer:
    for (final p in kPlaces) {
      for (final a in p.aliases) {
        final i = lower.indexOf(a);
        if (i >= 0) {
          place = p;
          text = text.replaceRange(i, i + a.length, ' ');
          break outer;
        }
      }
    }

    return ParsedQuery(
      raw: input,
      from: from,
      to: to,
      months: months,
      kind: kind,
      place: place,
      semantic: _cleanSemantic(text),
      dateLabel: dateLabel,
      textTerms: textTerms,
    );
  }

  /// 移除抽出條件後殘留的連接詞（在、拍的、的…）。
  static String _cleanSemantic(String s) {
    var t = s
        .replaceAll(RegExp(r'(拍攝|拍|錄|照)的'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final edge = RegExp(r'^(在|於|的|去|到|和|跟|與|,|，|、|\s)+|(在|於|的|時|,|，|、|\s)+$');
    String prev;
    do {
      prev = t;
      t = t.replaceAll(edge, '');
    } while (t != prev);
    // 中間殘留的「在 的」等孤立虛詞
    t = t.replaceAll(RegExp(r'(?<=\s|^)(在|於|的)(?=\s|$)'), ' ');
    return t.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
