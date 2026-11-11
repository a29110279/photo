import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_prompt/services/bert_tokenizer.dart';

/// 以真實 vocab 驗證 Dart 版 tokenizer 與 Hugging Face 版輸出一致。
/// 資料由 tools/verify_model.py 產生；一般執行 `flutter test` 時會略過，
/// 由 export-model workflow 設定環境變數後執行。
void main() {
  final vocabPath = Platform.environment['VOCAB_PATH'];
  final casesPath = Platform.environment['CASES_PATH'];

  test(
    'Dart tokenizer 與 Hugging Face tokenizer 輸出相同',
    () {
      final tok = BertTokenizer.fromVocabText(
        File(vocabPath!).readAsStringSync(),
      );
      final data = jsonDecode(
        File(casesPath!).readAsStringSync(),
      ) as Map<String, dynamic>;
      final n = data['contextLength'] as int;
      for (final c in data['cases'] as List) {
        final text = c['text'] as String;
        expect(
          tok.encode(text, contextLength: n),
          List<int>.from(c['ids'] as List),
          reason: text,
        );
      }
    },
    skip: vocabPath == null || casesPath == null
        ? '需設定 VOCAB_PATH 與 CASES_PATH（由 export-model workflow 提供）'
        : false,
  );
}
