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

  /// Cloud-bound photos of the active account: badges and upload eligibility.
  Future<List<String>> cloudBoundMediaIds();

  /// Cloud-bound photos of every saved account: read-only protection.
  Future<List<String>> cloudProtectedMediaIds();
  Future<CloudStatus> cloudSwitchAccount(String accountId);
  Future<CloudStatus> cloudRemoveAccount(String accountId);
  Future<CloudStatus> cloudSetUploadScope(String mode, List<String> albums);
}

/// One saved account. Only the active account synchronizes.
class CloudAccount {
  const CloudAccount({
    required this.accountId,
    required this.endpoint,
    required this.username,
    this.userId,
    this.active = false,
    this.signedIn = false,
    this.lastSyncMs,
  });

  final String accountId, endpoint, username;
  final String? userId;
  final bool active, signedIn;
  final int? lastSyncMs;
}

/// Live sweep counters. The phase is `preparing`, `receiving`, `uploading`,
/// `finalizing`, `idle` or `error`; the settings page turns these into the
/// detailed progress text.
class CloudActivity {
  const CloudActivity({
    this.phase = 'idle',
    this.syncing = false,
    this.startedAtMs,
    this.downloaded = 0,
    this.downloadTotal = 0,
    this.uploaded = 0,
    this.uploadTotal = 0,
    this.favoritesApplied = 0,
    this.favoritesUploaded = 0,
    this.favoriteTotal = 0,
    this.skipped = 0,
    this.failed = 0,
    this.errorCode,
  });

  final String phase;
  final bool syncing;
  final int? startedAtMs;
  final int downloaded, downloadTotal;
  final int uploaded, uploadTotal;
  final int favoritesApplied, favoritesUploaded, favoriteTotal;
  final int skipped, failed;
  final String? errorCode;

  bool get hasDownloadWork => downloadTotal > 0;
  bool get hasUploadWork => uploadTotal > 0 || favoriteTotal > 0;
}

class CloudStatus {
  const CloudStatus({
    this.loggedIn = false,
    this.accountId,
    this.endpoint,
    this.username,
    this.userId,
    this.tokenExpiresAtMs,
    this.lastSyncMs,
    this.state = 'logged_out',
    this.errorCode,
    this.pendingUploads = 0,
    this.failedUploads = 0,
    this.pendingFavorites = 0,
    this.boundCount = 0,
    this.uploadScope = 'none',
    this.uploadAlbums = const [],
    this.syncing = false,
    this.activity = const CloudActivity(),
    this.accounts = const [],
  });

  final bool loggedIn;
  final String? accountId, endpoint, username, userId;
  final int? tokenExpiresAtMs, lastSyncMs;
  final String state;
  final String? errorCode;
  final int pendingUploads, failedUploads, pendingFavorites, boundCount;
  final String uploadScope;
  final List<String> uploadAlbums;
  final bool syncing;
  final CloudActivity activity;
  final List<CloudAccount> accounts;

  CloudAccount? get activeAccount {
    for (final account in accounts) {
      if (account.active) return account;
    }
    return null;
  }
}

class CloudSyncReport {
  const CloudSyncReport({
    this.downloaded = 0,
    this.downloadTotal = 0,
    this.uploaded = 0,
    this.uploadTotal = 0,
    this.favoritesApplied = 0,
    this.favoritesUploaded = 0,
    this.favoriteTotal = 0,
    this.skipped = 0,
    this.failed = 0,
    this.state = 'idle',
    this.errorCode,
  });

  final int downloaded, downloadTotal;
  final int uploaded, uploadTotal;
  final int favoritesApplied, favoritesUploaded, favoriteTotal;
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
  'AccountNotFound',
  'InvalidUploadScope',
  'CloudScopeChanged',
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
