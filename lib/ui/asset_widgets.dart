import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:video_player/video_player.dart';

import '../state/providers.dart';
import 'theme.dart';

String formatDuration(int seconds) {
  final m = seconds ~/ 60, s = seconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// 縮圖方格。點一下切換選取（若提供 [onTap]），長按開啟預覽。
class AssetTile extends ConsumerWidget {
  const AssetTile({
    super.key,
    required this.assetId,
    this.selected,
    this.badge,
    this.onTap,
  });

  final String assetId;

  /// null 表示不顯示選取狀態。
  final bool? selected;
  final String? badge;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entity = ref.watch(assetEntityProvider(assetId)).value;
    final scheme = Theme.of(context).colorScheme;
    void preview() => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ViewerPage(assetId: assetId)),
    );

    final picked = selected == true;
    return GestureDetector(
      onTap: onTap ?? preview,
      onLongPress: preview,
      // 右下留 4px 給選取時的實心陰影，格線間距因此一致。
      child: Padding(
        padding: const EdgeInsets.only(right: 4, bottom: 4),
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              if (picked)
                const BoxShadow(
                  color: AppColors.deepBlue,
                  offset: Offset(4, 4),
                ),
            ],
          ),
          foregroundDecoration: BoxDecoration(
            border: Border.fromBorderSide(AppTheme.inkSide),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (entity != null)
                Image(
                  image: AssetEntityImageProvider(
                    entity,
                    isOriginal: false,
                    thumbnailSize: const ThumbnailSize.square(256),
                  ),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) =>
                      const Icon(Icons.broken_image_outlined),
                ),
              if (entity?.type == AssetType.video)
                Positioned(
                  left: 6,
                  bottom: 6,
                  child: _Chip('▶ ${formatDuration(entity!.duration)}'),
                ),
              if (badge != null)
                Positioned(right: 6, bottom: 6, child: _Chip(badge!)),
              if (selected != null)
                Positioned(
                  right: 6,
                  top: 6,
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: picked ? AppColors.yellow : Colors.white,
                      shape: BoxShape.circle,
                      border: Border.fromBorderSide(AppTheme.inkSide),
                    ),
                    child: picked
                        ? const Icon(
                            Icons.check,
                            size: 16,
                            color: AppColors.ink,
                            weight: 900,
                          )
                        : null,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: AppColors.ink,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );
}

/// 單一相片／影片預覽（C2）。
class ViewerPage extends ConsumerWidget {
  const ViewerPage({super.key, required this.assetId});
  final String assetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entity = ref.watch(assetEntityProvider(assetId));
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        shape: const Border(),
        systemOverlayStyle: SystemUiOverlayStyle.light,
        title: Text(
          entity.value == null
              ? ''
              : entity.value!.createDateTime.toString().substring(0, 16),
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: Colors.white,
            letterSpacing: 0,
          ),
        ),
        actions: [
          if (ref.watch(modelProvider).ready)
            IconButton(
              tooltip: '找相似（以圖搜圖）',
              icon: const Icon(Icons.image_search),
              onPressed: () {
                ref.read(searchProvider.notifier).searchByImage(assetId);
                ref.read(homeTabProvider.notifier).go(0);
                Navigator.of(context).popUntil((r) => r.isFirst);
              },
            ),
        ],
      ),
      body: Center(
        child: entity.when(
          loading: () => const CircularProgressIndicator(),
          error: (e, _) =>
              Text('$e', style: const TextStyle(color: Colors.white)),
          data: (e) {
            if (e == null) {
              return const Text(
                '找不到此項目',
                style: TextStyle(color: Colors.white),
              );
            }
            if (e.type == AssetType.video) return _VideoView(entity: e);
            return InteractiveViewer(
              maxScale: 5,
              child: Image(
                image: AssetEntityImageProvider(e, isOriginal: true),
                fit: BoxFit.contain,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _VideoView extends StatefulWidget {
  const _VideoView({required this.entity});
  final AssetEntity entity;

  @override
  State<_VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends State<_VideoView> {
  VideoPlayerController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final File? file = await widget.entity.file;
      if (file == null) throw StateError('無法讀取影片檔');
      final c = VideoPlayerController.file(file);
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _controller = c);
      await c.play();
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (_error != null) {
      return Text(_error!, style: const TextStyle(color: Colors.white));
    }
    if (c == null) return const CircularProgressIndicator();
    return GestureDetector(
      onTap: () => setState(() => c.value.isPlaying ? c.pause() : c.play()),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: AspectRatio(
              aspectRatio: c.value.aspectRatio,
              child: VideoPlayer(c),
            ),
          ),
          VideoProgressIndicator(c, allowScrubbing: true),
        ],
      ),
    );
  }
}
