import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/album_service.dart';
import '../services/query_parser.dart';
import '../services/search_service.dart';
import '../state/providers.dart';
import 'asset_widgets.dart';
import 'cleanup_page.dart' show confirmAndTrash;
import 'theme.dart';

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

  /// 條件標籤上的 X：移除該條件，組回提示詞並重新搜尋。
  void _removeCondition(QueryPart? part, {String? term}) {
    final ctrl = ref.read(searchProvider.notifier);
    final result = ref.read(searchProvider).result;
    if (result == null) return;
    // 以圖搜圖或已修正的結果：回到一般搜尋（或清空）。
    final next = part == null || result.byImage
        ? (result.byImage ? '' : result.query.toPrompt())
        : result.query.without(part, term: term).toPrompt();
    setState(() => _text.text = next);
    if (next.trim().isEmpty) {
      ctrl.clear();
    } else {
      ctrl.search(next);
    }
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
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ComicHeader(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: SizedBox(
                    height: 44,
                    child: Row(
                      children: [
                        Text(
                          '理理相簿',
                          style: Theme.of(context).appBarTheme.titleTextStyle,
                        ),
                        const Spacer(),
                        if (result != null &&
                            !result.byImage &&
                            result.query.raw.isNotEmpty)
                          IconButton(
                            tooltip: '存成智慧相簿',
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.white,
                              foregroundColor: AppColors.ink,
                              shape: const ComicBorder(shadow: 3),
                            ),
                            icon: const Icon(
                              Icons.auto_awesome_motion_outlined,
                            ),
                            onPressed: () => _saveSmartAlbum(
                              result.query.raw,
                              s.activeThreshold,
                            ),
                          ),
                        const SizedBox(width: 3),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 20, 18),
                  child: SearchBar(
                    controller: _text,
                    hintText: '描述想找的相片，例如：去年日本的海邊',
                    leading: const Icon(Icons.search),
                    trailing: [
                      if (_text.text.isNotEmpty)
                        IconButton(
                          tooltip: '清除',
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            _text.clear();
                            ctrl.clear();
                            setState(() {});
                          },
                        ),
                    ],
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _submit(),
                    textInputAction: TextInputAction.search,
                  ),
                ),
              ],
            ),
          ),
          if (model.progress != null)
            const InfoBanner('首次啟動：正在準備語意模型，約需數十秒…', icon: Icons.downloading)
          else if (!model.ready && !model.loading)
            const InfoBanner('此安裝檔未內建語意模型：目前只能用日期、地點、類型篩選。'),
          if (index.syncing)
            const InfoBanner('正在讀取媒體庫…完成後會自動更新搜尋結果。', icon: Icons.sync)
          else if (index.total == 0)
            InfoBanner(
              index.syncError == null
                  ? '沒有讀取到任何相片或影片，請到「設定」確認權限。'
                  : '讀取媒體庫失敗：${index.syncError}',
              error: index.syncError != null,
            ),
          if (model.ready && index.pending > 0)
            InfoBanner(
              '尚有 ${index.pending} 個項目未索引，語意搜尋結果可能不完整。',
              icon: Icons.hourglass_bottom,
            ),
          if (result != null) _QueryChips(result, onRemove: _removeCondition),
          if (result != null && result.usesThreshold)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 0),
              child: Row(
                children: [
                  Icon(
                    Icons.tune,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
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
                  SizedBox(
                    width: 36,
                    child: Text(s.activeThreshold.toStringAsFixed(2)),
                  ),
                ],
              ),
            ),
          if (result != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 8, 0),
              child: Row(
                children: [
                  Text(
                    '${visible.length} 個結果'
                    '${s.selected.isEmpty ? '' : '・已選 ${s.selected.length}'}',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const Spacer(),
                  PopupMenuButton<SearchSort>(
                    tooltip: '排序',
                    icon: const Icon(Icons.sort),
                    onSelected: ctrl.setSort,
                    itemBuilder: (_) {
                      // 沒有語意分數的結果只能依時間排；此時「相關度」等同新到舊。
                      final current = s.byTime && s.sort == SearchSort.relevance
                          ? SearchSort.newest
                          : s.sort;
                      return [
                        for (final (value, label) in [
                          if (result.isSemantic) (SearchSort.relevance, '依相關度'),
                          (SearchSort.newest, '依時間：新到舊'),
                          (SearchSort.oldest, '依時間：舊到新'),
                        ])
                          CheckedPopupMenuItem(
                            value: value,
                            checked: current == value,
                            child: Text(label),
                          ),
                      ];
                    },
                  ),
                  PopupMenuButton<String>(
                    tooltip: '選取',
                    icon: const Icon(Icons.checklist),
                    onSelected: (v) => switch (v) {
                      'all' => ctrl.selectAll(),
                      'invert' => ctrl.invertSelection(),
                      _ => ctrl.clearSelection(),
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'all', child: Text('全選')),
                      PopupMenuItem(value: 'invert', child: Text('反選')),
                      PopupMenuItem(value: 'clear', child: Text('清除選取')),
                    ],
                  ),
                  if (result.isSemantic)
                    IconButton(
                      tooltip: '依選取修正結果：選取的視為相關，排在前面但沒選的視為不相關',
                      icon: const Icon(Icons.auto_fix_high),
                      onPressed: s.selected.isEmpty ? null : ctrl.refine,
                    ),
                ],
              ),
            ),
          Expanded(
            child: s.busy
                ? const Center(child: CircularProgressIndicator())
                : result == null
                ? _Hint(
                    onPick: (q) {
                      _text.text = q;
                      _submit();
                    },
                  )
                : visible.isEmpty
                ? _EmptyResult(
                    result.isSemantic
                        ? '沒有符合的項目，可試著調低相關度'
                        : '沒有符合條件的項目\n'
                              '媒體庫共 ${index.photos} 張相片、${index.videos} 部影片',
                  )
                : _ResultGrid(
                    hits: visible,
                    selected: s.selected,
                    byTime: s.byTime,
                    onTap: ctrl.toggle,
                  ),
          ),
        ],
      ),
      // 選取後顯示操作列：加入（搬移）相簿或刪除。
      bottomNavigationBar: s.selected.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 20, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Theme.of(context).colorScheme.error,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: const Icon(Icons.delete_outline),
                        label: Text('刪除 ${s.selected.length} 個'),
                        onPressed: () => _delete(s.selected.toList()),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: const Icon(Icons.create_new_folder_outlined),
                        label: Text(AlbumService.movesFiles ? '搬移到相簿' : '加入相簿'),
                        onPressed: () => _addToAlbum(s.selected.toList()),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  /// 刪除選取的項目：移到系統垃圾桶／最近刪除（可復原），並從結果中移除。
  Future<void> _delete(List<String> ids) async {
    final gone = await confirmAndTrash(context, ref, ids);
    if (gone == null || gone.isEmpty) return;
    ref.read(searchProvider.notifier).removeAssets(gone);
    ref.invalidate(albumsProvider);
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

class _EmptyResult extends StatelessWidget {
  const _EmptyResult(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.image_search_outlined,
            size: 56,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

/// 搜尋結果格線；依時間排列時按月份分組。
class _ResultGrid extends StatelessWidget {
  const _ResultGrid({
    required this.hits,
    required this.selected,
    required this.byTime,
    required this.onTap,
  });

  final List<SearchHit> hits;
  final Set<String> selected;
  final bool byTime;
  final ValueChanged<String> onTap;

  static const _delegate = SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: 128,
    mainAxisSpacing: 6,
    crossAxisSpacing: 6,
  );

  Widget _tile(SearchHit h) => AssetTile(
    key: ValueKey(h.asset.id),
    assetId: h.asset.id,
    selected: selected.contains(h.asset.id),
    badge: h.score?.toStringAsFixed(2),
    onTap: () => onTap(h.asset.id),
  );

  @override
  Widget build(BuildContext context) {
    if (!byTime) {
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 4, 12, 96),
        gridDelegate: _delegate,
        itemCount: hits.length,
        itemBuilder: (_, i) => _tile(hits[i]),
      );
    }
    final title = Theme.of(context).textTheme.titleSmall;
    return CustomScrollView(
      slivers: [
        for (final g in groupByMonth(hits)) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: Text(
                '${g.year} 年 ${g.month} 月・${g.hits.length} 個',
                style: title,
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 12, 6),
            sliver: SliverGrid.builder(
              gridDelegate: _delegate,
              itemCount: g.hits.length,
              itemBuilder: (_, i) => _tile(g.hits[i]),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 96)),
      ],
    );
  }
}

/// 尚未搜尋時的說明與範例（點一下直接搜尋）。
class _Hint extends StatelessWidget {
  const _Hint({required this.onPick});
  final ValueChanged<String> onPick;

  static const _examples = [
    '去年夏天的海邊',
    '上個月在台北拍的影片',
    '2023年5月 貓',
    '寫著「發票」的照片',
    '海邊 不要有人',
    '夜景',
    '生日蛋糕',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        Text('試試看', style: theme.textTheme.titleSmall),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in _examples)
              ActionChip(
                avatar: const Icon(Icons.north_west, size: 16),
                label: Text(e),
                onPressed: () => onPick(e),
              ),
          ],
        ),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '可以同時描述時間、地點、類型與內容，'
              '用引號指定相片中的文字、輸入已命名的人物，'
              '或用「不要…」排除不想看到的內容。\n\n'
              '點縮圖可選取，長按可預覽；預覽頁右上角可「找相似」。',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 提示詞解析出的條件；每個標籤都可按 X 移除。
class _QueryChips extends StatelessWidget {
  const _QueryChips(this.result, {required this.onRemove});
  final SearchResult result;
  final void Function(QueryPart? part, {String? term}) onRemove;

  @override
  Widget build(BuildContext context) {
    final q = result.query;
    final chips = <(IconData, String, VoidCallback)>[
      if (result.byImage) (Icons.image_search, '以圖搜圖', () => onRemove(null)),
      if (!result.byImage) ...[
        if (q.dateLabel != null)
          (Icons.event, q.dateLabel!.trim(), () => onRemove(QueryPart.date)),
        if (q.place != null)
          (
            Icons.place_outlined,
            q.place!.name,
            () => onRemove(QueryPart.place),
          ),
        if (q.kind != null)
          (
            q.kind == MediaKind.video
                ? Icons.videocam_outlined
                : Icons.photo_outlined,
            q.kind == MediaKind.video ? '影片' : '相片',
            () => onRemove(QueryPart.kind),
          ),
        if (q.person != null)
          (Icons.person_outline, q.person!, () => onRemove(QueryPart.person)),
        for (final t in q.textTerms)
          (
            Icons.text_fields,
            '文字「$t」',
            () => onRemove(QueryPart.text, term: t),
          ),
        for (final t in q.exclude)
          (Icons.block, '排除：$t', () => onRemove(QueryPart.exclude, term: t)),
        if (q.semantic.isNotEmpty)
          (
            Icons.auto_awesome_outlined,
            q.semantic,
            () => onRemove(QueryPart.semantic),
          ),
      ],
      if (result.refined) (Icons.auto_fix_high, '已依選取修正', () => onRemove(null)),
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final c in chips)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InputChip(
                avatar: Icon(c.$1, size: 18),
                label: Text(c.$2),
                onDeleted: c.$3,
                deleteButtonTooltipMessage: '移除此條件',
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
