import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'cloud_sync_controller.dart';
import 'strings.dart';
import 'thumbnail_progress.dart';

/// One activity line in the photo header. A running cloud sweep wins over
/// thumbnail indexing so its counters cannot be hidden behind it.
class LibraryActivityProgress extends ConsumerWidget {
  const LibraryActivityProgress({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncing = ref.watch(
      cloudSyncProvider.select(
        (state) => state.syncRunning || state.status.syncing,
      ),
    );
    return syncing ? const CloudSyncProgress() : const ThumbnailProgress();
  }
}

class CloudSyncProgress extends ConsumerWidget {
  const CloudSyncProgress({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncing = ref.watch(
      cloudSyncProvider.select(
        (state) => state.syncRunning || state.status.syncing,
      ),
    );
    if (!syncing) return const SizedBox.shrink();
    final activity = ref.watch(
      cloudSyncProvider.select((state) => state.status.activity),
    );
    final strings = AppStrings.of(context);
    final text = switch (activity.phase) {
      'receiving' when activity.downloadTotal > 0 =>
        strings.cloudSyncLiveProgress(
          activity.downloaded,
          activity.downloadTotal,
        ),
      'receiving' => strings.cloudSyncLive,
      'uploading' when activity.uploadTotal > 0 =>
        strings.cloudUploadLiveProgress(
          activity.uploaded,
          activity.uploadTotal,
        ),
      'uploading' when activity.favoriteTotal > 0 =>
        strings.cloudFavoriteLiveProgress(
          activity.favoritesUploaded,
          activity.favoriteTotal,
        ),
      'uploading' => strings.cloudUploadLive,
      'finalizing' => strings.cloudSyncFinalizing,
      _ => strings.cloudSyncLive,
    };
    return Tooltip(
      message: text,
      child: Text(
        text,
        key: const ValueKey('cloud-sync-progress'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
