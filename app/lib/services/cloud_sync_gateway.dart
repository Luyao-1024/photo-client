/// Cloud sync contract. All protocol work happens in the native core through
/// the pinned sync-client SDK; the UI only sees stable codes and counters.
abstract interface class CloudSyncGateway {
  Future<CloudStatus> cloudLogin({
    required String endpoint,
    required String username,
    required String password,
  });
  Future<CloudStatus> cloudLogout();
  Future<CloudStatus> cloudStatus();
  Future<CloudSyncReport> cloudSyncNow();
  Future<CloudQueueResult> cloudQueueUpload(List<String> mediaIds);
  Future<List<String>> cloudBoundMediaIds();
}

class CloudStatus {
  const CloudStatus({
    this.loggedIn = false,
    this.endpoint,
    this.username,
    this.userId,
    this.tokenExpiresAtMs,
    this.lastSyncMs,
    this.state = 'logged_out',
    this.errorCode,
    this.pendingUploads = 0,
    this.pendingFavorites = 0,
    this.boundCount = 0,
    this.syncing = false,
  });

  final bool loggedIn;
  final String? endpoint, username, userId;
  final int? tokenExpiresAtMs, lastSyncMs;
  final String state;
  final String? errorCode;
  final int pendingUploads, pendingFavorites, boundCount;
  final bool syncing;
}

class CloudSyncReport {
  const CloudSyncReport({
    this.downloaded = 0,
    this.uploaded = 0,
    this.favoritesApplied = 0,
    this.favoritesUploaded = 0,
    this.skipped = 0,
    this.failed = 0,
    this.state = 'idle',
    this.errorCode,
  });

  final int downloaded, uploaded, favoritesApplied, favoritesUploaded;
  final int skipped, failed;
  final String state;
  final String? errorCode;

  bool get changedAnything =>
      downloaded > 0 ||
      uploaded > 0 ||
      favoritesApplied > 0 ||
      favoritesUploaded > 0;
}

class CloudQueueResult {
  const CloudQueueResult({
    this.queued = 0,
    this.skipped = 0,
    this.rejected = 0,
  });

  final int queued, skipped, rejected;
}

/// Error codes emitted by the native cloud engine.
const List<String> kCloudErrorCodes = [
  'AuthFailed',
  'TokenExpired',
  'Network',
  'EndpointRejected',
  'AccountExists',
  'AdminAccountUnsupported',
  'LeaseBusy',
  'LeaseLost',
  'NotCurrent',
  'GraphInvalid',
  'ChangeFailed',
  'UnsupportedMedia',
  'ThumbnailFailed',
  'QuotaExceeded',
  'SourceChanged',
  'LibraryClosed',
  'ServerRejected',
  'Internal',
];

/// Native errors arrive as stable code strings; unknown wrappers never reach
/// the UI as raw text.
String cloudErrorCode(Object error) {
  final text = '$error';
  for (final code in kCloudErrorCodes) {
    if (text.contains(code)) return code;
  }
  return 'Internal';
}
