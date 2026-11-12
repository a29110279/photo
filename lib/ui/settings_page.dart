import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

import '../state/providers.dart';
import 'theme.dart';

/// 設定：索引進度（自動執行，不需手動操作）、文字辨識、權限。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(indexProvider);
    final model = ref.watch(modelProvider);
    final perm = ref.watch(permissionProvider).value;
    final ocrOn = ref.watch(ocrEnabledProvider);
    final facesOn = ref.watch(facesEnabledProvider);
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final errorStyle = TextStyle(color: theme.colorScheme.error);

    final status = index.syncing
        ? '正在讀取媒體庫…'
        : model.progress != null
        ? '首次啟動：正在準備模型…'
        : index.running
        ? '索引中…'
        : index.pending > 0
        ? '尚有未完成的項目，會在背景自動繼續'
        : '已完成';

    final progress = index.syncing || index.total == 0
        ? null
        : (index.done + index.failed) / index.total;

    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          SectionCard(
            icon: Icons.manage_search,
            title: '索引',
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    progress == null
                        ? '—'
                        : '${(progress * 100).toStringAsFixed(0)}%',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      '${index.done} / ${index.total}'
                      '${index.failed > 0 ? '（${index.failed} 個無法處理）' : ''}',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 10),
              Text(
                index.msPerItem == null
                    ? status
                    : '$status（平均每個項目 ${index.msPerItem} 毫秒）',
                style: small,
              ),
              if (index.timing != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('每個項目：${index.timing}', style: small),
                ),
              if (model.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(model.error!, style: errorStyle),
                ),
              if (index.syncError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('讀取媒體庫失敗：${index.syncError}', style: errorStyle),
                ),
            ],
          ),
          const SizedBox(height: 12),
          SectionCard(
            icon: Icons.auto_awesome,
            title: '智慧功能',
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('文字辨識（OCR）'),
                subtitle: Text(
                  ocrOn
                      ? '已處理 ${index.ocrDone} / ${index.ocrTotal} 張。'
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
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('人物分群'),
                subtitle: Text(
                  facesOn
                      ? '已處理 ${index.faceDone} / ${index.faceTotal} 張。'
                            '結果在「相簿 › 人物」，命名後可直接搜尋名字'
                      : '辨識相片中的人臉並依人物分組；會增加索引時間',
                ),
                value: facesOn,
                onChanged: (v) async {
                  await ref.read(facesEnabledProvider.notifier).set(v);
                  if (v) {
                    await ref.read(indexProvider.notifier).autoIndex();
                  } else {
                    await ref.read(indexProvider.notifier).refresh();
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          SectionCard(
            icon: Icons.lock_outline,
            title: '權限與隱私',
            children: [
              Text(switch (perm) {
                PermissionState.authorized => '已授權存取全部相片',
                PermissionState.limited => '僅授權部分相片（只會索引可存取的項目）',
                _ => '未授權',
              }),
              const SizedBox(height: 4),
              Text('相片與搜尋內容只在這台裝置上處理，不會上傳。', style: small),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
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
            ],
          ),
        ],
      ),
    );
  }
}
