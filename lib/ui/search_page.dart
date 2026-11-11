import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/album_service.dart';
import '../services/query_parser.dart';
import '../services/search_service.dart';
import '../state/providers.dart';
import 'asset_widgets.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    FocusScope.of(context).unfocus();
    ref.read(searchProvider.notifier).search(_text.text);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(searchProvider);
    final ctrl = ref.read(searchProvider.notifier);
    final model = ref.watch(modelProvider);
    final index = ref.watch(indexProvider);
    final visible = s.visible;
    final result = s.result;

    // 媒體庫讀取完成後，重新執行目前的文字搜尋，避免顯示讀取前的空結果。
    ref.listen(indexProvider.select((p) => p.syncing), (was, now) {
      final r = ref.read(searchProvider).result;
      if (was == true && !now && r != null && !r.byImage) {
        ctrl.search(r.query.raw);
      }
    });

    ref.listen(searchProvider.select((v) => v.error), (_, err) {
      if (err != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(err)));
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('提示詞搜尋'),
        actions: [
          if (result != null && !result.byImage && result.query.raw.isNotEmpty)
            IconButton(
              tooltip: '存成智慧相簿',
              icon: const Icon(Icons.auto_awesome_motion_outlined),
              onPressed: () =>
                  _saveSmartAlbum(result.query.raw, s.activeThreshold),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: TextField(
              controller: _text,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                hintText: '例如：去年在日本拍的海邊影片',
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: _submit,
                ),
              ),
            ),
          ),
          if (model.progress != null)
            const _Banner('首次啟動：正在準備語意模型，約需數十秒…')
          else if (!model.ready && !model.loading)
            const _Banner('此安裝檔未內建語意模型：目前只能用日期、地點、類型篩選。'),
          if (index.syncing)
            const _Banner('正在讀取媒體庫…完成後會自動更新搜尋結果。')
          else if (index.total == 0)
            _Banner(
              index.syncError == null
                  ? '沒有讀取到任何相片或影片。請到「設定」確認權限，或按「重新讀取媒體庫」。'
                  : '讀取媒體庫失敗：${index.syncError}',
            ),
          if (model.ready && index.pending > 0)
            _Banner('尚有 ${index.pending} 個項目未索引，語意搜尋結果可能不完整。'),
          if (result != null) _QueryChips(result),
          if (result != null && result.isSemantic)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  const Text('相關度'),
                  Expanded(
                    child: Slider(
                      value: s.activeThreshold.clamp(
                        0.0,
                        result.byImage ? 1.0 : 0.5,
                      ),
                      max: result.byImage ? 1.0 : 0.5,
                      divisions: 50,
                      label: s.activeThreshold.toStringAsFixed(2),
                      onChanged: ctrl.setThreshold,
                      onChangeEnd: (_) => ctrl.saveThreshold(),
                    ),
                  ),
                  Text(s.activeThreshold.toStringAsFixed(2)),
                ],
              ),
            ),
          if (result != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      '${visible.length} 個結果・已選 ${s.selected.length}',
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: ctrl.selectAll,
                    child: const Text('全選'),
                  ),
                  TextButton(
                    onPressed: ctrl.invertSelection,
                    child: const Text('反選'),
                  ),
                  TextButton(
                    onPressed: ctrl.clearSelection,
                    child: const Text('清除'),
                  ),
                  if (result.isSemantic)
                    IconButton(
                      tooltip: '依選取修正結果：選取的視為相關，排在前面但沒選的視為不相關',
                      icon: const Icon(Icons.tune),
                      onPressed: s.selected.isEmpty ? null : ctrl.refine,
                    ),
                ],
              ),
            ),
          Expanded(
            child: s.busy
                ? const Center(child: CircularProgressIndicator())
                : result == null
                ? const _Hint()
                : visible.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        result.isSemantic
                            ? '沒有符合的項目，可試著調低相關度'
                            : '沒有符合條件的項目\n'
                                  '（媒體庫共 ${index.photos} 張相片、${index.videos} 部影片）',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.all(2),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 130,
                          mainAxisSpacing: 2,
                          crossAxisSpacing: 2,
                        ),
                    itemCount: visible.length,
                    itemBuilder: (_, i) {
                      final h = visible[i];
                      return AssetTile(
                        key: ValueKey(h.asset.id),
                        assetId: h.asset.id,
                        selected: s.selected.contains(h.asset.id),
                        badge: h.score?.toStringAsFixed(2),
                        onTap: () => ctrl.toggle(h.asset.id),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: s.selected.isEmpty
          ? null
          : FloatingActionButton.extended(
              icon: const Icon(Icons.create_new_folder_outlined),
              label: Text(AlbumService.movesFiles ? '搬移到相簿' : '加入相簿'),
              onPressed: () => _addToAlbum(s.selected.toList()),
            ),
    );
  }

  /// 智慧相簿（O5）：保存目前的提示詞與門檻。
  Future<void> _saveSmartAlbum(String prompt, double threshold) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) {
        String? error;
        return StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: const Text('存成智慧相簿'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('提示詞：$prompt\n門檻：${threshold.toStringAsFixed(2)}'),
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: '相簿名稱',
                    errorText: error,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '之後新索引的項目若符合條件，會出現在「相簿 › 智慧相簿」，按一下即可加入。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  final err = AlbumService.validateName(controller.text);
                  if (err != null) {
                    setState(() => error = err);
                  } else {
                    Navigator.pop(context, controller.text.trim());
                  }
                },
                child: const Text('儲存'),
              ),
            ],
          ),
        );
      },
    );
    controller.dispose();
    if (name == null || !mounted) return;
    await ref.read(storeProvider).createSmartAlbum(name, prompt, threshold);
    ref.invalidate(smartAlbumsProvider);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已建立智慧相簿「$name」')));
  }

  /// 搬移前預覽與確認（O1），完成後提供一鍵復原。
  Future<void> _addToAlbum(List<String> ids) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _AlbumDialog(ids: ids),
    );
    if (name == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final albums = ref.read(albumServiceProvider);
    try {
      final r = await albums.addToAlbum(name, ids);
      ref.read(searchProvider.notifier).afterAlbumOp();
      ref.invalidate(opLogProvider);
      ref.invalidate(albumsProvider);
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          content: Text('已${r.moved ? '搬移' : '加入'} ${r.count} 個項目到「$name」'),
          action: SnackBarAction(
            label: '復原',
            onPressed: () async {
              try {
                await albums.undo(r.logId);
                messenger.showSnackBar(const SnackBar(content: Text('已復原')));
              } on Object catch (e) {
                messenger.showSnackBar(SnackBar(content: Text('$e')));
              }
              ref.invalidate(opLogProvider);
              ref.invalidate(albumsProvider);
            },
          ),
        ),
      );
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

class _Banner extends StatelessWidget {
  const _Banner(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: TextStyle(color: scheme.onSecondaryContainer)),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint();

  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(24),
      child: Text(
        '輸入想找的內容，可包含時間、地點與類型。\n\n'
        '・去年夏天的海邊\n・上個月在台北拍的影片\n・2023年5月 貓\n'
        '・寫著「發票」的照片（需在設定開啟文字辨識）\n\n'
        '長按縮圖可預覽，預覽頁右上角可「找相似」。',
        textAlign: TextAlign.center,
      ),
    ),
  );
}

/// 顯示提示詞被解析成哪些條件，讓使用者知道篩選依據。
class _QueryChips extends StatelessWidget {
  const _QueryChips(this.result);
  final SearchResult result;

  @override
  Widget build(BuildContext context) {
    final q = result.query;
    if (result.byImage) {
      return _chipRow([
        (Icons.image_search, '以圖搜圖'),
        if (result.refined) (Icons.tune, '已依選取修正'),
      ]);
    }
    return _chipRow([
      if (q.dateLabel != null) (Icons.event, q.dateLabel!),
      if (q.place != null) (Icons.place_outlined, q.place!.name),
      if (q.kind != null)
        (
          q.kind == MediaKind.video
              ? Icons.videocam_outlined
              : Icons.photo_outlined,
          q.kind == MediaKind.video ? '影片' : '相片',
        ),
      if (q.person != null) (Icons.person_outline, q.person!),
      for (final t in q.textTerms) (Icons.text_fields, '文字「$t」'),
      if (q.semantic.isNotEmpty) (Icons.auto_awesome_outlined, q.semantic),
      if (result.refined) (Icons.tune, '已依選取修正'),
    ]);
  }

  Widget _chipRow(List<(IconData, String)> chips) {
    if (chips.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final c in chips)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Chip(
                avatar: Icon(c.$1, size: 16),
                label: Text(c.$2),
                visualDensity: VisualDensity.compact,
              ),
            ),
        ],
      ),
    );
  }
}

class _AlbumDialog extends StatefulWidget {
  const _AlbumDialog({required this.ids});
  final List<String> ids;

  @override
  State<_AlbumDialog> createState() => _AlbumDialogState();
}

class _AlbumDialogState extends State<_AlbumDialog> {
  final _name = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final moves = AlbumService.movesFiles;
    final preview = widget.ids.take(12).toList();
    return AlertDialog(
      title: Text(moves ? '搬移到相簿' : '加入相簿'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('共 ${widget.ids.length} 個項目'),
            const SizedBox(height: 8),
            SizedBox(
              height: 56,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final id in preview)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: SizedBox(
                        width: 56,
                        child: AssetTile(assetId: id, onTap: () {}),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              autofocus: true,
              decoration: InputDecoration(
                labelText: '相簿名稱（不存在會自動建立）',
                errorText: _error,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              moves
                  ? '檔案會實際搬到 ${AlbumService.androidPath('<相簿名稱>')}，'
                        '系統會跳出一次授權確認。之後可從「相簿 › 操作紀錄」復原。'
                  : '項目會加入相簿，原本的位置不變。之後可從「相簿 › 操作紀錄」復原。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final err = AlbumService.validateName(_name.text);
            if (err != null) {
              setState(() => _error = err);
            } else {
              Navigator.pop(context, _name.text.trim());
            }
          },
          child: const Text('確認'),
        ),
      ],
    );
  }
}
