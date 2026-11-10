import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'data/local_store.dart';
import 'state/providers.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final support = await getApplicationSupportDirectory();
  final store = await LocalStore.open(p.join(support.path, 'photo_prompt.db'));
  runApp(ProviderScope(
    overrides: [
      storeProvider.overrideWithValue(store),
      modelDirProvider.overrideWithValue(p.join(support.path, 'models')),
    ],
    child: const PhotoPromptApp(),
  ));
}
