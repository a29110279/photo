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

/// 單次背景執行的時間上限。Android 以前景服務執行（通知欄會顯示），
/// 可超過 WorkManager 一般任務約 10 分鐘的限制；用完後自動接續下一輪。
// Android 15 的 dataSync 前景服務每天最多 6 小時；接續的下一輪若被系統擋下，
// 仍有每小時一次的定期任務接手。
const _budget = Duration(hours: 3);

/// Android 前景服務的通知設定。
ForegroundServiceConfig get _foreground => ForegroundServiceConfig(
  notificationTitle: '理理相簿',
  notificationText: '正在背景建立索引，完成後會自動停止',
  notificationChannelId: 'indexing',
  notificationChannelName: '背景索引',
  notificationId: 7101,
  foregroundServiceType: ForegroundServiceType.dataSync,
);

Future<String> databasePath() async =>
    p.join((await getApplicationSupportDirectory()).path, 'photo_prompt.db');

Future<String> modelDirPath() async =>
    p.join((await getApplicationSupportDirectory()).path, 'models');

/// 背景引擎的進入點。
@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((task, input) async {
    try {
      final more = await runBackgroundIndexing();
      // 時間用完但還沒做完：排下一輪接著做（名稱交替，避免取代正在執行的這一輪）。
      if (more && Platform.isAndroid) {
        final round = ((input?['round'] as int?) ?? 0) + 1;
        await _scheduleAndroid('$_oneOffName.${round % 2}', round);
      }
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
/// 回傳是否因時間用完而中斷、仍有待處理的項目。
Future<bool> runBackgroundIndexing() async {
  DartPluginRegistrant.ensureInitialized();
  // 獨立連線：結束時關閉不會影響前景 App 的連線。
  final store = await LocalStore.open(
    await databasePath(),
    singleInstance: false,
  );
  EmbeddingService? embedder;
  FaceService? faces;
  try {
    // 任務在 App 離開畫面時就排程，前景可能還沒停：稍等前景交棒。
    for (var i = 0; i < 12 && await _foregroundActive(store); i++) {
      await Future<void>.delayed(const Duration(seconds: 5));
    }
    if (await _foregroundActive(store)) return false;
    final perm = await PhotoManager.getPermissionState(
      requestOption: MediaRepository.request,
    );
    if (!perm.hasAccess) return false;

    final installed = await ModelService(await modelDirPath())
        .ensureBundled(rootBundle);
    embedder = installed == null
        ? null
        : await EmbeddingService.load(installed);
    // 影片抽幀與 OCR 的原生通道由本地外掛 native_media 提供，背景引擎也會註冊。
    // OCR 與人物分群預設開啟，只有使用者關閉時（'0'）才略過。
    final withOcr = await store.getSetting(SettingKeys.ocrEnabled) != '0';
    if (await store.getSetting(SettingKeys.facesEnabled) != '0') {
      faces = await FaceService.load(rootBundle, await modelDirPath());
    }
    final completed = await IndexingService(store, const MediaRepository()).run(
      embedder,
      withOcr: withOcr,
      faces: faces,
      timeBudget: _budget,
      shouldStop: () => _foregroundActive(store),
    );
    return !completed && !await _foregroundActive(store);
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

Future<void> _scheduleAndroid(String name, int round) =>
    Workmanager().registerOneOffTask(
      name,
      kIndexTask,
      inputData: {'round': round},
      constraints: Constraints(requiresBatteryNotLow: true),
      existingWorkPolicy: ExistingWorkPolicy.replace,
      foregroundServiceConfig: _foreground,
    );

/// App 進入背景時呼叫：立即以前景服務在背景接著索引。
Future<void> scheduleBackgroundIndexing() async {
  if (Platform.isAndroid) {
    await _scheduleAndroid('$_oneOffName.0', 0);
  } else if (Platform.isIOS) {
    // iOS 由系統決定何時執行（通常是充電、閒置時），唯一名稱需與 Info.plist 相同。
    await Workmanager().registerProcessingTask(kIndexTask, kIndexTask);
  }
}
