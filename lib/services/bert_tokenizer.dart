/// BERT WordPiece tokenizer（Chinese-CLIP 文字編碼器使用）。
/// 中日韓字元逐字切分，其餘以空白/標點切分後做 WordPiece。
class BertTokenizer {
  BertTokenizer(this.vocab)
    : cls = vocab['[CLS]'] ?? 101,
      sep = vocab['[SEP]'] ?? 102,
      pad = vocab['[PAD]'] ?? 0,
      unk = vocab['[UNK]'] ?? 100;

  /// 由 vocab.txt 內容建立（每行一個 token，行號即 id）。
  factory BertTokenizer.fromVocabText(String text) {
    final vocab = <String, int>{};
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final t = lines[i].trimRight();
      if (t.isNotEmpty) vocab[t] = i;
    }
    return BertTokenizer(vocab);
  }

  final Map<String, int> vocab;
  final int cls, sep, pad, unk;

  static bool _isCjk(int c) =>
      (c >= 0x4E00 && c <= 0x9FFF) ||
      (c >= 0x3400 && c <= 0x4DBF) ||
      (c >= 0xF900 && c <= 0xFAFF) ||
      (c >= 0x20000 && c <= 0x2FA1F);

  static bool _isPunct(int c) =>
      (c >= 33 && c <= 47) ||
      (c >= 58 && c <= 64) ||
      (c >= 91 && c <= 96) ||
      (c >= 123 && c <= 126) ||
      (c >= 0x3000 && c <= 0x303F) ||
      (c >= 0xFF00 && c <= 0xFFEF) ||
      (c >= 0x2000 && c <= 0x206F);

  List<String> _basicTokens(String text) {
    final out = <String>[];
    final buf = StringBuffer();
    void flush() {
      if (buf.isNotEmpty) {
        out.add(buf.toString());
        buf.clear();
      }
    }

    for (final rune in text.toLowerCase().runes) {
      final ch = String.fromCharCode(rune);
      if (ch.trim().isEmpty) {
        flush();
      } else if (_isCjk(rune) || _isPunct(rune)) {
        flush();
        out.add(ch);
      } else {
        buf.write(ch);
      }
    }
    flush();
    return out;
  }

  List<int> _wordPiece(String word) {
    if (word.length > 100) return [unk];
    final ids = <int>[];
    var start = 0;
    while (start < word.length) {
      var end = word.length;
      int? cur;
      while (start < end) {
        final sub = (start > 0 ? '##' : '') + word.substring(start, end);
        final id = vocab[sub];
        if (id != null) {
          cur = id;
          break;
        }
        end--;
      }
      if (cur == null) return [unk];
      ids.add(cur);
      start = end;
    }
    return ids;
  }

  /// 回傳長度固定為 [contextLength] 的 token id（含 [CLS]/[SEP]，不足補 [PAD]）。
  List<int> encode(String text, {int contextLength = 52}) {
    final ids = <int>[cls];
    for (final w in _basicTokens(text)) {
      ids.addAll(_wordPiece(w));
    }
    if (ids.length > contextLength - 1) {
      ids.removeRange(contextLength - 1, ids.length);
    }
    ids.add(sep);
    while (ids.length < contextLength) {
      ids.add(pad);
    }
    return ids;
  }
}
