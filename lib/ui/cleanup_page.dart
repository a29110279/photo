import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../data/local_store.dart';
import '../data/media_sizes.dart';
import '../state/providers.dart';
import 'asset_widgets.dart';

/// 整理：相似照片（O6）、截圖與螢幕錄影、模糊照片（O10）、最佔空間的項目。
class CleanupPage extends StatelessWidget {
  const CleanupPage({super.key});

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 4,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('整理'),
        bottom: const TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(text: '相似照片'),
            Tab(text: '截圖與錄影'),
            Tab(text: '模糊照片'),
            Tab(text: '佔空間'),
          ],
        ),
      ),
      body: const TabBarView(
        children: [_SimilarTab(), _ScreenshotTab(), _BlurTab(), _LargestTab()],
      ),
    ),
  );
}

/// 確認後移到系統垃圾桶，並自資料庫移除；回傳實際刪除的 id（取消為 null）。
Future<Set<String>?> confirmAndTrash(
  BuildContext context,
  WidgetRef ref,
  List<String> ids,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('刪除 ${ids.length} 個項目？'),
      content: const Text(
        '會移到系統的垃圾桶（Android）或「最近刪除」（iOS），'
        '在系統相簿內仍可復原。系統會再跳出一次確認。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('刪除'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return null;
  final messenger = ScaffoldMessenger.of(context);
  try {
    final deleted = await ref.read(mediaRepositoryProvider).trash(ids);
    await ref.read(storeProvider).removeAssets(deleted);
    messenger.showSnackBar(
      SnackBar(content: Text('已刪除 ${deleted.length} 個項目')),
    );
    return deleted.toSet();
  } on Object catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
    return null;
  }
}

class _SimilarTab extends ConsumerStatefulWidget {
  const _SimilarTab();

  @override
  ConsumerState<_SimilarTab> createState() => _SimilarTabState();
}

class _SimilarTabState extends ConsumerState<_SimilarTab> {
  double _threshold = 0.95;
  bool _nearbyOnly = true;
  bool _busy = false;
  List<List<String>>? _groups;
  final _selected = <String>{};

  Future<void> _scan() async {
    final embedder = ref.read(modelProvider).embedder;
    if (embedder == null) return;
    setState(() => _busy = true);
    try {
      final groups = await ref
          .read(duplicateServiceProvider)
          .findGroups(
            modelVersion: embedder.version,
            dim: embedder.dim,
            threshold: _threshold,
            windowHours: _nearbyOnly ? 6 : null,
          );
      _selected
        ..clear()
        // 預設保留每群第一張（最早拍攝），其餘勾選待刪。
        ..addAll([for (final g in groups) ...g.skip(1)]);
      setState(() => _groups = groups);
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _trash() async {
    final gone = await confirmAndTrash(context, ref, _selected.toList());
    if (gone == null || !mounted) return;
    setState(() {
      _selected.removeAll(gone);
      _groups = [
        for (final g in _groups ?? const <List<String>>[])
          if (g.where((id) => !gone.contains(id)).length > 1)
            [
              for (final id in g)
                if (!gone.contains(id)) id,
            ],
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    final ready = ref.watch(modelProvider).ready;
    final groups = _groups;
    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<double>(
                  segments: const [
                    ButtonSegment(value: 0.90, label: Text('相似')),
                    ButtonSegment(value: 0.95, label: Text('非常相似')),
                    ButtonSegment(value: 0.98, label: Text('幾乎相同')),
                  ],
                  selected: {_threshold},
                  onSelectionChanged: (v) =>
                      setState(() => _threshold = v.first),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('只比對 6 小時內拍攝的相片'),
                  subtitle: const Text('關閉後會全部兩兩比對，可找到重複存檔，但較慢'),
                  value: _nearbyOnly,
                  onChanged: (v) => setState(() => _nearbyOnly = v),
                ),
                FilledButton.icon(
                  onPressed: ready && !_busy ? _scan : null,
                  icon: const Icon(Icons.search),
                  label: Text(ready ? '掃描' : '需模型就緒並完成索引'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _busy
                ? const Center(child: CircularProgressIndicator())
                : groups == null
                ? const Center(child: Text('只會比對已索引的相片'))
                : groups.isEmpty
                ? const Center(child: Text('沒有找到相似的相片'))
                : ListView.builder(
                    itemCount: groups.length,
                    itemBuilder: (_, i) => _GroupRow(
                      ids: groups[i],
                      selected: _selected,
                      onToggle: (id) => setState(() {
                        if (!_selected.remove(id)) _selected.add(id);
                      }),
                    ),
                  ),
          ),
        ],
      ),
      floatingActionButton: _selected.isEmpty
          ? null
          : FloatingActionButton.extended(
              icon: const Icon(Icons.delete_outline),
              label: Text('刪除 ${_selected.length} 個'),
              onPressed: _trash,
            ),
    );
  }
}

class _GroupRow extends StatelessWidget {
  const _GroupRow({
    required this.ids,
    required this.selected,
    required this.onToggle,
  });
  final List<String> ids;
  final Set<String> selected;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SizedBox(
        height: 110,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          children: [
            for (final id in ids)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: SizedBox(
                  width: 110,
                  child: AssetTile(
                    key: ValueKey(id),
                    assetId: id,
                    selected: selected.contains(id),
                    onTap: () => onToggle(id),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 截圖與螢幕錄影（O10）。
class _ScreenshotTab extends ConsumerWidget {
  const _ScreenshotTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) => _PickAndTrash(
    provider: screenshotsProvider,
    emptyText: '沒有找到截圖或螢幕錄影',
    hint: '依時間新到舊排列。Android 依所在資料夾判斷，iOS 依系統標記（iOS 的螢幕錄影無法辨識）。',
  );
}

/// 模糊照片（O10）：依清晰度由低到高排列，由使用者挑選。
class _BlurTab extends ConsumerWidget {
  const _BlurTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) => _PickAndTrash(
    provider: blurriestProvider,
    emptyText: '尚無清晰度資料，索引完成後會出現在這裡',
    hint: '由最模糊開始排列，數字為清晰度（越小越模糊）。夜景、霧景等低對比照片也可能排在前面，請確認後再刪除。',
    badge: (a) => a.sharpness?.toStringAsFixed(0),
  );
}

/// 最佔空間的相片與影片，由大到小。
class _LargestTab extends ConsumerWidget {
  const _LargestTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sizes = ref.watch(mediaSizesProvider).value ?? const <String, int>{};
    return _PickAndTrash(
      provider: largestProvider,
      emptyText: '沒有可顯示的項目（此功能目前只支援 Android）',
      hint: '由最大的檔案開始排列，最多顯示 300 個。影片通常最佔空間，刪除前可長按預覽。',
      badge: (a) => switch (sizes[a.id]) {
        final int b => formatBytes(b),
        null => null,
      },
      selectedInfo: (ids) =>
          formatBytes(ids.fold(0, (sum, id) => sum + (sizes[id] ?? 0))),
    );
  }
}

/// 可多選並刪除的縮圖清單。
class _PickAndTrash extends ConsumerStatefulWidget {
  const _PickAndTrash({
    required this.provider,
    required this.emptyText,
    required this.hint,
    this.badge,
    this.selectedInfo,
  });

  final ProviderListenable<AsyncValue<List<AssetRecord>>> provider;
  final String emptyText;
  final String hint;
  final String? Function(AssetRecord)? badge;

  /// 選取項目的補充說明（例如總大小），顯示在已選數量後面。
  final String Function(Set<String> selected)? selectedInfo;

  @override
  ConsumerState<_PickAndTrash> createState() => _PickAndTrashState();
}

class _PickAndTrashState extends ConsumerState<_PickAndTrash> {
  final _selected = <String>{};
  final _gone = <String>{};

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(widget.provider);
    return Scaffold(
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (all) {
          final items = [
            for (final a in all)
              if (!_gone.contains(a.id)) a,
          ];
          if (items.isEmpty) return Center(child: Text(widget.emptyText));
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Text(
                  widget.hint,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Text(
                      '${items.length} 個・已選 ${_selected.length}'
                      '${_selected.isEmpty || widget.selectedInfo == null ? '' : '（${widget.selectedInfo!(_selected)}）'}',
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => setState(
                      () => _selected.addAll(items.map((a) => a.id)),
                    ),
                    child: const Text('全選'),
                  ),
                  TextButton(
                    onPressed: () => setState(_selected.clear),
                    child: const Text('清除'),
                  ),
                ],
              ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(2),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 130,
                    mainAxisSpacing: 2,
                    crossAxisSpacing: 2,
                  ),
                  itemCount: items.length,
                  itemBuilder: (_, i) {
                    final a = items[i];
                    return AssetTile(
                      key: ValueKey(a.id),
                      assetId: a.id,
                      selected: _selected.contains(a.id),
                      badge: widget.badge?.call(a),
                      onTap: () => setState(() {
                        if (!_selected.remove(a.id)) _selected.add(a.id);
                      }),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: _selected.isEmpty
          ? null
          : FloatingActionButton.extended(
              icon: const Icon(Icons.delete_outline),
              label: Text('刪除 ${_selected.length} 個'),
              onPressed: () async {
                final gone = await confirmAndTrash(
                  context,
                  ref,
                  _selected.toList(),
                );
                if (gone == null || !mounted) return;
                setState(() {
                  _gone.addAll(gone);
                  _selected.removeAll(gone);
                });
              },
            ),
    );
  }
}
