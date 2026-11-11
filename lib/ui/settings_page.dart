import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

import '../state/providers.dart';

/// 設定：索引進度（自動執行，不需手動操作）、文字辨識、權限。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(indexProvider);
    final model = ref.watch(modelProvider);
    final perm = ref.watch(permissionProvider).value;
    final ocrOn = ref.watch(ocrEnabledProvider);
    final theme = Theme.of(context);
    final titleStyle = theme.textTheme.titleMedium;
    final small = theme.textTheme.bodySmall;
    final errorStyle = TextStyle(color: theme.colorScheme.error);

    final status = index.syncing
        ? '正在讀取媒體庫…'
        : model.progress != null
        ? '首次啟動：正在準備模型…'
        : index.running
        ? '索引中…'
        : index.pending > 0
        ? '尚有未完成的項目，App 開啟或手機閒置時會自動繼續'
        : '已完成';

    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('索引', style: titleStyle),
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: index.syncing || index.total == 0
                ? null
                : (index.done + index.failed) / index.total,
          ),
          const SizedBox(height: 8),
          Text(
            '${index.done} / ${index.total}'
            '${index.failed > 0 ? '（${index.failed} 個無法處理）' : ''}',
          ),
          const SizedBox(height: 4),
          Text(status, style: small),
          if (model.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(model.error!, style: errorStyle),
            ),
          if (index.syncError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('讀取媒體庫失敗：${index.syncError}', style: errorStyle),
            ),
          const Divider(height: 32),
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
            onChanged: (v) async {
              await ref.read(ocrEnabledProvider.notifier).set(v);
              if (v) {
                await ref.read(indexProvider.notifier).autoIndex();
              } else {
                await ref.read(indexProvider.notifier).refresh();
              }
            },
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
              const OutlinedButton(
                onPressed: PhotoManager.openSetting,
                child: Text('開啟系統設定'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text('相片與搜尋內容只在這台裝置上處理，不會上傳。', style: small),
        ],
      ),
    );
  }
}
