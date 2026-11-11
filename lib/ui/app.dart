import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

import '../state/providers.dart';
import 'albums_page.dart';
import 'cleanup_page.dart';
import 'search_page.dart';
import 'settings_page.dart';

class PhotoPromptApp extends StatelessWidget {
  const PhotoPromptApp({super.key});

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal, brightness: b),
      useMaterial3: true,
    );
    return MaterialApp(
      title: '提示詞相簿',
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: const PermissionGate(),
    );
  }
}

/// 權限閘門（C1）：未授權時顯示說明，授權（含部分存取）後進入主畫面。
class PermissionGate extends ConsumerWidget {
  const PermissionGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perm = ref.watch(permissionProvider);
    return perm.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(body: Center(child: Text('權限檢查失敗：$e'))),
      data: (state) {
        if (state.hasAccess) return const HomeShell();
        final denied =
            state == PermissionState.denied ||
            state == PermissionState.restricted;
        return Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.photo_library_outlined, size: 72),
                  const SizedBox(height: 16),
                  Text(
                    '需要相片存取權限',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '所有分析都在這台裝置上進行，相片與搜尋內容不會離開裝置。',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: () =>
                        ref.read(permissionProvider.notifier).request(),
                    child: const Text('授權存取'),
                  ),
                  if (denied)
                    TextButton(
                      onPressed: PhotoManager.openSetting,
                      child: const Text('前往系統設定開啟'),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // 回到前景時重新讀取媒體庫，納入在其他 App 新增或刪除的相片。
    _lifecycle = AppLifecycleListener(
      onResume: () => ref.read(indexProvider.notifier).resync(),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  /// 模型尚未安裝且已知下載網址時，首次開啟詢問是否下載（只問一次）。
  Future<void> _maybePromptModel() async {
    final model = ref.read(modelProvider);
    if (model.loading || model.ready || model.progress != null) return;
    final store = ref.read(storeProvider);
    if (await store.getSetting(SettingKeys.modelPrompted) != null) return;
    final url = await ref.read(modelProvider.notifier).manifestUrl();
    if (url.isEmpty || !mounted) return;
    await store.setSetting(SettingKeys.modelPrompted, '1');
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('下載語意模型？'),
        content: const Text(
          '用文字描述搜尋相片（例如「海邊夕陽」）需要先下載模型，約數百 MB，建議使用 Wi-Fi。\n\n'
          '這是 App 唯一的網路行為，相片不會上傳。之後也可以在「設定」下載。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('稍後'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('下載'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    ref.read(homeTabProvider.notifier).go(3);
    await ref.read(modelProvider.notifier).download(url);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(modelProvider.select((m) => m.loading), (was, now) {
      if (was == true && !now) _maybePromptModel();
    });
    final index = ref.watch(homeTabProvider);
    return Scaffold(
      body: IndexedStack(
        index: index,
        children: const [
          SearchPage(),
          AlbumsPage(),
          CleanupPage(),
          SettingsPage(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: ref.read(homeTabProvider.notifier).go,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.search), label: '搜尋'),
          NavigationDestination(
            icon: Icon(Icons.photo_album_outlined),
            label: '相簿',
          ),
          NavigationDestination(
            icon: Icon(Icons.cleaning_services_outlined),
            label: '整理',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            label: '設定',
          ),
        ],
      ),
    );
  }
}
