import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

import '../data/local_store.dart';
import '../services/album_service.dart';
import '../state/providers.dart';
import 'asset_widgets.dart';

/// 相簿管理：裝置相簿瀏覽（C2）與操作紀錄／復原（O1）。
class AlbumsPage extends ConsumerWidget {
  const AlbumsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('相簿'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () {
                ref.invalidate(albumsProvider);
                ref.invalidate(opLogProvider);
                ref.invalidate(smartAlbumsProvider);
                ref.invalidate(smartAlbumPendingProvider);
              },
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: '相簿'),
              Tab(text: '智慧相簿'),
              Tab(text: '操作紀錄'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [_AlbumList(), _SmartAlbumList(), _OpLogList()],
        ),
      ),
    );
  }
}

class _AlbumList extends ConsumerWidget {
  const _AlbumList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(albumsProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('$e')),
          data: (albums) => ListView.builder(
            itemCount: albums.length,
            itemBuilder: (_, i) {
              final a = albums[i];
              return ListTile(
                leading: const Icon(Icons.photo_album_outlined),
                title: Text(a.isAll ? '全部' : a.name),
                subtitle: FutureBuilder<int>(
                  future: a.assetCountAsync,
                  builder: (_, s) => Text(s.hasData ? '${s.data} 個項目' : ''),
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AlbumDetailPage(album: a),
                  ),
                ),
              );
            },
          ),
        );
  }
}

class AlbumDetailPage extends StatefulWidget {
  const AlbumDetailPage({super.key, required this.album});
  final AssetPathEntity album;

  @override
  State<AlbumDetailPage> createState() => _AlbumDetailPageState();
}

class _AlbumDetailPageState extends State<AlbumDetailPage> {
  static const _pageSize = 120;
  final _ids = <String>[];
  int _total = 0;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading) return;
    _loading = true;
    final total = await widget.album.assetCountAsync;
    final start = _ids.length;
    final list = start >= total
        ? const <AssetEntity>[]
        : await widget.album.getAssetListRange(
            start: start,
            end: (start + _pageSize).clamp(0, total),
          );
    _loading = false;
    if (!mounted) return;
    setState(() {
      _total = total;
      _ids.addAll(list.map((e) => e.id));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.album.isAll ? '全部' : widget.album.name),
      ),
      body: GridView.builder(
        padding: const EdgeInsets.all(2),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 130,
          mainAxisSpacing: 2,
          crossAxisSpacing: 2,
        ),
        itemCount: _ids.length,
        itemBuilder: (_, i) {
          if (i >= _ids.length - 20 && _ids.length < _total) _loadMore();
          return AssetTile(key: ValueKey(_ids[i]), assetId: _ids[i]);
        },
      ),
    );
  }
}

class _OpLogList extends ConsumerWidget {
  const _OpLogList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(opLogProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('$e')),
          data: (logs) => logs.isEmpty
              ? const Center(child: Text('尚無操作紀錄'))
              : ListView.builder(
                  itemCount: logs.length,
                  itemBuilder: (_, i) => _OpLogTile(logs[i]),
                ),
        );
  }
}

class _OpLogTile extends ConsumerWidget {
  const _OpLogTile(this.log);
  final OpLogEntry log;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final verb = log.kind == 'move' ? '搬移' : '加入';
    return ListTile(
      leading: Icon(log.undone ? Icons.undo : Icons.drive_file_move_outlined),
      title: Text('$verb ${log.items.length} 個項目到「${log.albumName}」'),
      subtitle: Text(
        '${log.ts.toString().substring(0, 16)}${log.undone ? '・已復原' : ''}',
      ),
      trailing: log.undone
          ? null
          : TextButton(
              child: const Text('復原'),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                try {
                  await ref.read(albumServiceProvider).undo(log.id);
                  messenger.showSnackBar(const SnackBar(content: Text('已復原')));
                } on Object catch (e) {
                  messenger.showSnackBar(SnackBar(content: Text('$e')));
                }
                ref.invalidate(opLogProvider);
                ref.invalidate(albumsProvider);
              },
            ),
    );
  }
}

// ---- 智慧相簿（O5） ----

class _SmartAlbumList extends ConsumerWidget {
  const _SmartAlbumList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(smartAlbumsProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('$e')),
          data: (rules) => rules.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      '在搜尋頁右上角「存成智慧相簿」，之後符合條件的新項目會出現在這裡。',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: rules.length,
                  itemBuilder: (_, i) => _SmartAlbumTile(rules[i]),
                ),
        );
  }
}

class _SmartAlbumTile extends ConsumerWidget {
  const _SmartAlbumTile(this.rule);
  final SmartAlbum rule;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(smartAlbumPendingProvider(rule));
    return ListTile(
      leading: const Icon(Icons.auto_awesome_motion_outlined),
      title: Text(rule.name),
      subtitle: Text('${rule.prompt}・門檻 ${rule.threshold.toStringAsFixed(2)}'),
      trailing: pending.when(
        loading: () => const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        error: (_, _) => const Icon(Icons.error_outline),
        data: (ids) => ids.isEmpty
            ? const Text('無新項目')
            : Badge(
                label: Text('${ids.length}'),
                child: const Icon(Icons.add_photo_alternate_outlined),
              ),
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => SmartAlbumPage(rule: rule)),
      ),
    );
  }
}

/// 檢視智慧相簿的待加入項目，取消勾選的項目之後不再提示。
class SmartAlbumPage extends ConsumerStatefulWidget {
  const SmartAlbumPage({super.key, required this.rule});
  final SmartAlbum rule;

  @override
  ConsumerState<SmartAlbumPage> createState() => _SmartAlbumPageState();
}

class _SmartAlbumPageState extends ConsumerState<SmartAlbumPage> {
  Set<String>? _selected;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final pending = ref.watch(smartAlbumPendingProvider(widget.rule));
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.rule.name),
        actions: [
          IconButton(
            tooltip: '刪除規則',
            icon: const Icon(Icons.delete_outline),
            onPressed: _deleteRule,
          ),
        ],
      ),
      body: pending.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (ids) {
          final selected = _selected ??= ids.toSet();
          if (ids.isEmpty) return const Center(child: Text('目前沒有符合的新項目'));
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  '提示詞：${widget.rule.prompt}\n'
                  '已選 ${selected.length} / ${ids.length}。未勾選的項目之後不會再提示。',
                ),
              ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(2),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 130,
                    mainAxisSpacing: 2,
                    crossAxisSpacing: 2,
                  ),
                  itemCount: ids.length,
                  itemBuilder: (_, i) => AssetTile(
                    key: ValueKey(ids[i]),
                    assetId: ids[i],
                    selected: selected.contains(ids[i]),
                    onTap: () => setState(() {
                      if (!selected.remove(ids[i])) selected.add(ids[i]);
                    }),
                  ),
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _busy ? null : () => _apply(ids, selected),
                      child: Text(
                        AlbumService.movesFiles
                            ? '搬移 ${selected.length} 個項目到「${widget.rule.name}」'
                            : '加入 ${selected.length} 個項目到「${widget.rule.name}」',
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _apply(List<String> ids, Set<String> selected) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await ref
          .read(smartAlbumServiceProvider)
          .apply(
            widget.rule,
            [
              for (final id in ids)
                if (selected.contains(id)) id,
            ],
            skipped: [
              for (final id in ids)
                if (!selected.contains(id)) id,
            ],
          );
      messenger.showSnackBar(
        SnackBar(
          content: Text(r == null ? '已更新' : '已處理 ${r.count} 個項目，可從操作紀錄復原'),
        ),
      );
      _selected = null;
      ref.invalidate(smartAlbumPendingProvider(widget.rule));
      ref.invalidate(opLogProvider);
      ref.invalidate(albumsProvider);
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteRule() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('刪除智慧相簿規則？'),
        content: const Text('只刪除規則，相簿與裡面的相片不受影響。'),
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
    await ref.read(storeProvider).deleteSmartAlbum(widget.rule.id);
    ref.invalidate(smartAlbumsProvider);
    if (mounted) Navigator.pop(context);
  }
}
