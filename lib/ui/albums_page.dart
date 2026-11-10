import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

import '../data/local_store.dart';
import '../state/providers.dart';
import 'asset_widgets.dart';

/// 相簿管理：裝置相簿瀏覽（C2）與操作紀錄／復原（O1）。
class AlbumsPage extends ConsumerWidget {
  const AlbumsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('相簿'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () {
                ref.invalidate(albumsProvider);
                ref.invalidate(opLogProvider);
              },
            ),
          ],
          bottom: const TabBar(tabs: [Tab(text: '相簿'), Tab(text: '操作紀錄')]),
        ),
        body: const TabBarView(children: [_AlbumList(), _OpLogList()]),
      ),
    );
  }
}

class _AlbumList extends ConsumerWidget {
  const _AlbumList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref.watch(albumsProvider).when(
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
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => AlbumDetailPage(album: a))),
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
            start: start, end: (start + _pageSize).clamp(0, total));
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
      appBar: AppBar(title: Text(widget.album.isAll ? '全部' : widget.album.name)),
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
    return ref.watch(opLogProvider).when(
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
          '${log.ts.toString().substring(0, 16)}${log.undone ? '・已復原' : ''}'),
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
