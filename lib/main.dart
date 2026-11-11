import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'background/background_indexing.dart';
import 'data/local_store.dart';
import 'state/providers.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await LocalStore.open(await databasePath());
  try {
    await initBackgroundIndexing();
  } on Object {
    // 背景索引無法啟用時，仍可在前景索引。
  }
  runApp(
    ProviderScope(
      overrides: [
        storeProvider.overrideWithValue(store),
        modelDirProvider.overrideWithValue(await modelDirPath()),
      ],
      child: const PhotoPromptApp(),
    ),
  );
}
