import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

import '../state/providers.dart';

/// 設定：模型下載（C12）、索引控制（C5）、權限（C1）。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  @override
  Widget build(BuildContext context) {
    final model = ref.watch(modelProvider);
    final index = ref.watch(indexProvider);
    final perm = ref.watch(permissionProvider).value;
    final indexCtrl = ref.read(indexProvider.notifier);
    final ocrOn = ref.watch(ocrEnabledProvider);
    final titleStyle = Theme.of(context).textTheme.titleMedium;

    // 模型就緒（或更換）後重新計算索引進度。
    ref.listen(modelProvider.select((m) => m.embedder?.version), (_, _) {
      indexCtrl.refresh();
    });

    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('語意模型', style: titleStyle),
          const SizedBox(height: 8),
          if (model.progress != null) ...[
            Text('首次啟動：正在準備模型 ${(model.progress! * 100).toStringAsFixed(0)}%'),
            const SizedBox(height: 4),
            LinearProgressIndicator(value: model.progress),
          ] else
            Text(
              model.loading
                  ? '載入中…'
                  : model.ready
                  ? '已就緒：${model.embedder!.version}'
                  : '此安裝檔未內建模型，只能使用日期、地點、類型篩選',
            ),
          if (model.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                model.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 4),
          Text(
            '模型內建於 App，不需連網；相片與搜尋內容不會離開裝置。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const Divider(height: 32),
          Text('媒體庫', style: titleStyle),
          const SizedBox(height: 8),
          Text(
            index.syncing
                ? '讀取中…'
                : '相片 ${index.photos} 張、影片 ${index.videos} 部',
          ),
          if (index.syncError != null)
            Text(
              '讀取失敗：${index.syncError}',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: index.syncing || index.running ? null : indexCtrl.resync,
            icon: const Icon(Icons.sync),
            label: const Text('重新讀取媒體庫'),
          ),
          const Divider(height: 32),
          Text('索引', style: titleStyle),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: index.total == 0 ? 0 : index.done / index.total,
          ),
          const SizedBox(height: 4),
          Text(
            '已索引 ${index.done} / ${index.total}'
            '${index.failed > 0 ? '（失敗 ${index.failed}）' : ''}',
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('文字辨識（OCR）'),
            subtitle: Text(
              ocrOn
                  ? '已處理 ${index.ocrDone} / ${index.ocrTotal} 張相片。'
                        '搜尋時用引號指定文字，例如：「發票」'
                  : '可搜尋截圖、收據上的文字；會增加索引時間',
            ),
            value: ocrOn,
            onChanged: index.running
                ? null
                : (v) async {
                    await ref.read(ocrEnabledProvider.notifier).set(v);
                    await indexCtrl.refresh();
                  },
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              if (index.running)
                FilledButton.tonal(
                  onPressed: indexCtrl.stop,
                  child: const Text('暫停'),
                )
              else
                FilledButton(
                  onPressed: model.ready || ocrOn ? indexCtrl.start : null,
                  child: Text(index.done > 0 ? '繼續／更新索引' : '開始索引'),
                ),
              if (!index.running && index.failed > 0)
                OutlinedButton(
                  onPressed: () => indexCtrl.reset(onlyFailed: true),
                  child: const Text('重試失敗項目'),
                ),
              if (!index.running && index.done > 0)
                OutlinedButton(
                  onPressed: () => _confirmReset(indexCtrl),
                  child: const Text('清除並重建'),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '索引在 App 開啟時進行，可隨時暫停，下次會從中斷處繼續。最近的相片優先。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const Divider(height: 32),
          Text('權限', style: titleStyle),
          const SizedBox(height: 8),
          Text(switch (perm) {
            PermissionState.authorized => '已授權存取全部相片',
            PermissionState.limited => '僅授權部分相片（只會索引可存取的項目）',
            _ => '未授權',
          }),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              if (perm == PermissionState.limited)
                OutlinedButton(
                  onPressed: ref
                      .read(permissionProvider.notifier)
                      .manageLimited,
                  child: const Text('調整可存取的相片'),
                ),
              OutlinedButton(
                onPressed: PhotoManager.openSetting,
                child: const Text('開啟系統設定'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmReset(IndexController ctrl) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除並重建索引？'),
        content: const Text('會刪除所有已計算的索引資料（不影響相片本身），之後需重新索引。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (ok == true) await ctrl.reset();
  }
}
