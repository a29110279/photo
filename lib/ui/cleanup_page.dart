import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'asset_widgets.dart';

/// 整理：重複／相似照片（O6）。
class CleanupPage extends ConsumerStatefulWidget {
  const CleanupPage({super.key});

  @override
  ConsumerState<CleanupPage> createState() => _CleanupPageState();
}

class _CleanupPageState extends ConsumerState<CleanupPage> {
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
    final ids = _selected.toList();
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
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final deleted = await ref.read(mediaRepositoryProvider).trash(ids);
      await ref.read(storeProvider).removeAssets(deleted);
      final gone = deleted.toSet();
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
      messenger.showSnackBar(
        SnackBar(content: Text('已刪除 ${deleted.length} 個項目')),
      );
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = ref.watch(modelProvider).ready;
    final groups = _groups;
    return Scaffold(
      appBar: AppBar(title: const Text('整理：相似照片')),
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
                  label: Text(ready ? '掃描' : '需先下載模型並完成索引'),
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
