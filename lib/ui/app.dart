import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

import '../background/background_indexing.dart';
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
      title: '理理相簿',
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
  Timer? _heartbeat;

  @override
  void initState() {
    super.initState();
    _startHeartbeat();
    _lifecycle = AppLifecycleListener(
      // 回到前景：接手索引，並納入在其他 App 新增或修改的相片。
      onResume: () {
        _startHeartbeat();
        ref.read(indexProvider.notifier).autoIndex();
      },
      // 離開畫面時就排背景任務：此時 App 仍算在前景，Android 才允許啟動前景服務。
      onHide: () => scheduleBackgroundIndexing().catchError((_) {}),
      // 進入背景：停止前景索引，交給背景任務接著做。
      onPause: () {
        _stopHeartbeat();
        ref.read(indexProvider.notifier).pause();
      },
    );
  }

  /// 前景心跳：背景索引看到最近的心跳就會停下，避免兩邊同時索引。
  void _startHeartbeat() {
    void beat() => ref
        .read(storeProvider)
        .setSetting(
          SettingKeys.foregroundHeartbeat,
          '${DateTime.now().millisecondsSinceEpoch}',
        );
    _heartbeat?.cancel();
    beat();
    _heartbeat = Timer.periodic(const Duration(seconds: 20), (_) => beat());
  }

  void _stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
    ref.read(storeProvider).setSetting(SettingKeys.foregroundHeartbeat, '0');
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
