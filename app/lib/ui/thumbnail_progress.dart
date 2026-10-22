import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/thumbnail_pipeline.dart';
import '../services/local_library_gateway.dart';
import 'local_library_controller.dart';
import 'runtime_controller.dart';
import 'strings.dart';

final thumbnailProgressProvider =
    StreamProvider.autoDispose<Map<String, dynamic>>((ref) {
      final gateway = ref.watch(coreGatewayProvider);
      final ready = ref.watch(
        runtimeProvider.select((state) => state.phase == ConnectionPhase.ready),
      );
      if (!ready || gateway is! ThumbnailPipelineGateway) {
        return const Stream.empty();
      }
      ref.watch(
        localLibraryProvider.select(
          (library) => (library.revision, library.backgroundScanning),
        ),
      );
      final native = gateway as ThumbnailPipelineGateway;
      final pool = gateway is LocalLibraryGateway
          ? ThumbnailPool.forGateway(gateway as LocalLibraryGateway)
          : null;
      Timer? timer;
      final controller = StreamController<Map<String, dynamic>>();
      var busy = false, disposed = false;
      var activityGeneration = 0;
      Future<void> poll() async {
        if (busy || disposed) return;
        busy = true;
        final generation = activityGeneration;
        try {
          final result = await native.thumbnailCommand({
            'op': 'thumbnailStats',
          });
          if (!disposed && generation == activityGeneration && result is Map) {
            pool?.reportReady(
              result['size_class'] as int? ?? 512,
              result['ready'] as int? ?? 0,
            );
            controller.add(Map<String, dynamic>.from(result));
            final done =
                (result['ready'] as int? ?? 0) +
                    (result['failed'] as int? ?? 0) >=
                (result['total'] as int? ?? 0);
            if ((done || result['cache_limit_reached'] == true) &&
                result['reconciling'] != true &&
                result['queued'] == 0 &&
                result['running'] == 0 &&
                (pool?.desiredSize == null ||
                    result['size_class'] == pool!.desiredSize)) {
              timer?.cancel();
              timer = null;
            }
          }
        } catch (_) {
          /* Initialization and shutdown can overlap the poll. */
        } finally {
          busy = false;
          if (!disposed && generation != activityGeneration) unawaited(poll());
        }
      }

      void restart() {
        activityGeneration++;
        timer ??= Timer.periodic(
          const Duration(seconds: 1),
          (_) => unawaited(poll()),
        );
        unawaited(poll());
      }

      pool?.activity.addListener(restart);
      restart();
      ref.onDispose(() {
        disposed = true;
        timer?.cancel();
        pool?.activity.removeListener(restart);
        unawaited(controller.close());
      });
      return controller.stream;
    });

/// A separate consumer keeps progress ticks from rebuilding the photo grid.
class ThumbnailProgress extends ConsumerWidget {
  const ThumbnailProgress({super.key, this.alwaysShow = false});
  final bool alwaysShow;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(thumbnailProgressProvider).asData?.value;
    if (data == null) return const SizedBox.shrink();
    final total = data['total'] as int? ?? 0;
    final ready = data['ready'] as int? ?? 0;
    final failed = data['failed'] as int? ?? 0;
    if (total == 0 || (!alwaysShow && ready >= total)) {
      return const SizedBox.shrink();
    }
    final strings = AppStrings.of(context);
    final limited = data['cache_limit_reached'] == true;
    final text = limited
        ? strings.pick(
            '缩略图 $ready/$total · 缓存已达上限',
            'Thumbnails $ready/$total · cache limit reached',
          )
        : failed == 0
        ? strings.pick('缩略图 $ready/$total', 'Thumbnails $ready/$total')
        : strings.pick(
            '缩略图 $ready/$total · $failed 项暂时不可用',
            'Thumbnails $ready/$total · $failed unavailable',
          );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Text(
        text,
        key: const ValueKey('thumbnail-generation-progress'),
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}
