import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:workmanager/workmanager.dart';

import '../data/local_store.dart';
import '../data/media_repository.dart';
import '../data/setting_keys.dart';
import '../services/embedding_service.dart';
import '../services/face_service.dart';
import '../services/indexing_service.dart';
import '../services/model_service.dart';

/// 背景索引任務名稱。iOS 的 BGProcessingTask 識別碼需同時列在 Info.plist。
const kIndexTask = 'com.personal.photoPrompt.index';
const _periodicName = 'com.personal.photoPrompt.index.periodic';
const _oneOffName = 'com.personal.photoPrompt.index.once';

/// 前景心跳在此時間內視為 App 仍在前景，背景任務不執行或立即停止。
const kHeartbeatTimeout = Duration(seconds: 60);

/// 單次背景執行的時間上限（Android WorkManager 約 10 分鐘會被系統停止）。
const _budget = Duration(minutes: 8);

Future<String> databasePath() async =>
    p.join((await getApplicationSupportDirectory()).path, 'photo_prompt.db');

Future<String> modelDirPath() async =>
    p.join((await getApplicationSupportDirectory()).path, 'models');

/// 背景引擎的進入點。
@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((task, input) async {
    try {
      await runBackgroundIndexing();
    } on Object {
      // 失敗時下次排程會再試；回傳 true 避免系統無限重試耗電。
    }
    return true;
  });
}

Future<bool> _foregroundActive(LocalStore store) async {
  final hb = int.tryParse(
    await store.getSetting(SettingKeys.foregroundHeartbeat) ?? '',
  );
  if (hb == null) return false;
  return DateTime.now().millisecondsSinceEpoch - hb <
      kHeartbeatTimeout.inMilliseconds;
}

/// 在背景執行一輪增量索引；前景 App 啟動時會自動停止。
Future<void> runBackgroundIndexing() async {
  DartPluginRegistrant.ensureInitialized();
  final store = await LocalStore.open(await databasePath());
  EmbeddingService? embedder;
  FaceService? faces;
  try {
    if (await _foregroundActive(store)) return;
    final perm = await PhotoManager.getPermissionState(
      requestOption: MediaRepository.request,
    );
    if (!perm.hasAccess) return;

    final installed = await ModelService(await modelDirPath())
        .ensureBundled(rootBundle);
    embedder = installed == null
        ? null
        : await EmbeddingService.load(installed);
    // 影片抽幀與 OCR 的原生通道由本地外掛 native_media 提供，背景引擎也會註冊。
    final withOcr = await store.getSetting(SettingKeys.ocrEnabled) == '1';
    if (await store.getSetting(SettingKeys.facesEnabled) == '1') {
      faces = await FaceService.load(rootBundle, await modelDirPath());
    }
    await IndexingService(store, const MediaRepository()).run(
      embedder,
      withOcr: withOcr,
      faces: faces,
      timeBudget: _budget,
      shouldStop: () => _foregroundActive(store),
    );
  } finally {
    embedder?.dispose();
    faces?.dispose();
    await store.close();
  }
}

/// App 啟動時呼叫：初始化背景任務並註冊定期索引（Android）。
Future<void> initBackgroundIndexing() async {
  if (!Platform.isAndroid && !Platform.isIOS) return;
  await Workmanager().initialize(backgroundDispatcher);
  if (Platform.isAndroid) {
    await Workmanager().registerPeriodicTask(
      _periodicName,
      kIndexTask,
      frequency: const Duration(hours: 1),
      constraints: Constraints(requiresBatteryNotLow: true),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  }
}

/// App 進入背景時呼叫：還有未完成的索引就排一次背景任務接著做。
Future<void> scheduleBackgroundIndexing() async {
  if (Platform.isAndroid) {
    await Workmanager().registerOneOffTask(
      _oneOffName,
      kIndexTask,
      constraints: Constraints(requiresBatteryNotLow: true),
      existingWorkPolicy: ExistingWorkPolicy.replace,
    );
  } else if (Platform.isIOS) {
    // iOS 由系統決定何時執行（通常是充電、閒置時），唯一名稱需與 Info.plist 相同。
    await Workmanager().registerProcessingTask(kIndexTask, kIndexTask);
  }
}
