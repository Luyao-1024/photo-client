import 'package:flutter/widgets.dart';

/// Presentation copy catalog. Platform exceptions never become user-facing copy.
class AppStrings {
  AppStrings(Locale locale) : chinese = locale.languageCode == 'zh';
  final bool chinese;
  static AppStrings of(BuildContext context) =>
      AppStrings(Localizations.localeOf(context));
  String pick(String zh, String en) => chinese ? zh : en;

  String get appTitle => 'PhotoViewer';
  String get library => pick('照片', 'Photos');
  String get settings => pick('设置', 'Settings');
  String get appearance => pick('外观', 'Appearance');
  String get albums => pick('相册', 'Albums');
  String get albumFavorites => pick('收藏', 'Favorites');
  String get trash => pick('回收站', 'Trash');
  String get trashEmpty => pick(
    '回收站为空。删除的照片会先移到这里，可恢复或彻底删除。',
    'Trash is empty. Deleted photos land here first and can be restored or removed permanently.',
  );
  String get searchHint => pick('搜索照片', 'Search photos');
  String get modeYear => pick('年', 'Year');
  String get modeMonth => pick('月', 'Month');
  String get modeDay => pick('日', 'Day');
  String get today => pick('今天', 'Today');
  String get yesterday => pick('昨天', 'Yesterday');
  String selectedCountLabel(int n) => pick('已选择 $n 项', '$n selected');
  String get selectAll => pick('全选', 'Select all');
  String get deselectAll => pick('取消全选', 'Deselect all');
  String get exitSelection => pick('退出选择', 'Exit selection');
  String get addToAlbum => pick('添加到相册', 'Add to album');
  String get moveToTrash => pick('移到回收站', 'Move to trash');
  String get indexing => pick('正在索引…', 'Indexing…');
  String get scanFailed => pick('扫描失败', 'Scan failed');
  String get retryScan => pick('重新扫描', 'Retry scan');
  String get emptyLibrary => pick('照片为空', 'No photos yet');
  String get openSettings => pick('打开设置', 'Open settings');
  String get scanFolders => pick('扫描目录', 'Scan folders');
  String photosCountLabel(int n) => pick('$n 张照片', '$n photos');
  String positionLabel(int cur, int total) => '$cur / $total';
  String get libraryFailed => pick('照片加载失败', 'Photos failed to load');
  String get libraryFailedBody => pick(
    '无法打开本地照片。请重试；如果一直失败，请确认照片所在目录仍然可用。',
    'The photos could not be opened. Try again; if it keeps failing, check that your photo folders are still available.',
  );
  String get retry => pick('重试', 'Try again');
  String get theme => pick('主题', 'Theme');
  String get system => pick('跟随系统', 'System');
  String get light => pick('浅色', 'Light');
  String get dark => pick('深色', 'Dark');
  String get language => pick('语言', 'Language');
  String get appearanceBody => pick(
    '外观只影响界面。当前选择仅在本次运行中保留。',
    'Appearance affects the interface only. Choices last for this session.',
  );
  String get glass => pick('玻璃材质', 'Glass material');
  String get glassHint => pick(
    '导航、工具栏与弹窗使用统一玻璃材质。表单与菜单保持更高不透明度，保证阅读清晰。',
    'Navigation, toolbars and dialogs share one glass material. Forms and menus stay more opaque for clear reading.',
  );

  String get localStage => pick('本地图库', 'Local library');
  String get addFiles => pick('添加照片', 'Add photos');
  String get addFolder => pick('添加目录', 'Add folder');
  String get pickerUnavailable =>
      pick('当前平台尚未接入文件选择', 'File selection is unavailable on this platform');
  String get localEmpty =>
      pick('添加本地照片，开始浏览', 'Add local photos to start browsing');
  String get localEmptyBody => pick(
    '选择照片文件或目录，加入本地图库。',
    'Choose photo files or a folder to add to your local library.',
  );
  String get noMatches => pick('没有符合条件的照片', 'No matching photos');
  String get noMatchesBody => pick(
    '尝试其他搜索词，或关闭收藏筛选。',
    'Try another search or turn off the favorites filter.',
  );
  String get searchPhotos => pick('搜索照片', 'Search photos');
  String get favorites => pick('仅收藏', 'Favorites only');
  String get refresh => pick('刷新照片', 'Refresh photos');
  String get loadingLibrary => pick('正在读取本地照片…', 'Loading photos…');
  String get selecting => pick('正在选择来源…', 'Choosing a source…');
  String get cancelScan => pick('停止扫描', 'Stop scan');
  String get cancellingScan => pick('正在停止扫描…', 'Stopping scan…');
  String get scanning => pick('正在扫描本地来源…', 'Scanning local sources…');
  String get loadMore => pick('加载下一页', 'Load next page');
  String get imageUnavailable => pick('无法读取图片', 'Image unavailable');
  String get thumbnailUnavailable => pick('缩略图不可用', 'Thumbnail unavailable');
  String get retryImage => pick('重试图片', 'Retry image');
  String get back => pick('返回图库', 'Back to library');
  String get previous => pick('上一张', 'Previous photo');
  String get next => pick('下一张', 'Next photo');
  String get markFavorite => pick('收藏照片', 'Favorite photo');
  String get unmarkFavorite => pick('取消收藏', 'Remove favorite');
  String get details => pick('照片信息', 'Photo information');
  String get zoomIn => pick('放大', 'Zoom in');
  String get zoomOut => pick('缩小', 'Zoom out');
  String get zoomReset => pick('恢复缩放', 'Reset zoom');
  String get immersive => pick('沉浸浏览', 'Immersive view');
  String get exitImmersive => pick('退出沉浸浏览', 'Exit immersive view');
  String get close => pick('关闭', 'Close');
  String get filePath => pick('文件路径', 'File path');
  String get fileSize => pick('文件大小', 'File size');
  String get modified => pick('修改时间', 'Modified');
  String get dimensions => pick('尺寸', 'Dimensions');
  String get unknown => pick('未知', 'Unknown');
  String get libraryUpdated => pick(
    '照片已更新，返回后可继续浏览',
    'The photos changed. Return to continue browsing.',
  );
  String get folderFilter => pick('当前目录', 'Current folder');
  String photoCount(int count) => pick('$count 张照片', '$count photos');
  String librarySummary(int count, int revision) => pick(
    '图库：$count 张 · 修订 $revision',
    'Library: $count photos · revision $revision',
  );
  String scanSummary(
    int discovered,
    int skipped,
    int failed,
    bool cancelled,
  ) => pick(
    '${cancelled ? '扫描已取消' : '扫描已结束'}：发现 $discovered，跳过 $skipped，失败 $failed',
    '${cancelled ? 'Scan cancelled' : 'Scan finished'}: $discovered discovered, $skipped skipped, $failed failed',
  );
  // --- Sidebar sections -------------------------------------------------
  String get mediaTypes => pick('媒体类型', 'Media types');
  String get images => pick('图片', 'Images');
  String get videos => pick('视频', 'Videos');
  String get keyboardShortcuts => pick('键盘快捷键', 'Keyboard shortcuts');
  String get shortcutBrowse => pick('浏览', 'Browsing');
  String get shortcutViewer => pick('查看器', 'Viewer');
  String get shortcutGlobal => pick('全局', 'Global');

  // --- Search -----------------------------------------------------------
  String get search => pick('搜索', 'Search');
  String get searchAll => pick('全部', 'All');
  String get searchByName => pick('名称', 'Name');
  String get searchByDate => pick('日期', 'Date');
  String get searchPrompt => pick('输入关键词开始搜索', 'Type a keyword to search');
  String get searching => pick('正在搜索…', 'Searching…');

  // --- Multi-select / batch --------------------------------------------
  String get restore => pick('恢复', 'Restore');
  String get deletePermanently => pick('彻底删除', 'Delete permanently');
  String get emptyTrash => pick('清空回收站', 'Empty trash');
  String get copyToAlbum => pick('复制到相册', 'Copy to album');
  String get moveToAlbum => pick('移动到相册', 'Move to album');
  String get rename => pick('重命名', 'Rename');
  String get renamePhoto => pick('重命名照片', 'Rename photo');
  String get setAsCover => pick('设为封面', 'Set as cover');
  String get albumCover => pick('相册封面', 'Album cover');
  String get chooseAlbum => pick('选择目标相册', 'Choose a destination album');
  String get newAlbum => pick('新建相册…', 'New album…');
  String get noAlbums =>
      pick('还没有相册，先添加一个目录。', 'No albums yet. Add a folder first.');
  String get copy => pick('复制', 'Copy');
  String get move => pick('移动', 'Move');
  String get save => pick('保存', 'Save');
  String get cancel => pick('取消', 'Cancel');
  String get delete => pick('删除', 'Delete');

  // --- Dialogs / confirmations -----------------------------------------
  String confirmTrashTitle(int n) =>
      pick('将 $n 项移到回收站？', 'Move $n item(s) to trash?');
  String get confirmTrashBody => pick(
    '照片会移到回收站，可稍后恢复。',
    'Photos move to trash and can be restored later.',
  );
  String confirmPurgeTitle(int n) =>
      pick('彻底删除 $n 项？', 'Delete $n item(s) permanently?');
  String get confirmPurgeBody => pick(
    '此操作无法撤销，文件将从磁盘删除；已同步的照片也会从云端删除。',
    'This cannot be undone. Files are removed from disk, and synced photos are also deleted from the cloud.',
  );
  String get confirmEmptyTrashTitle => pick('清空回收站？', 'Empty trash?');
  String get confirmEmptyTrashBody => pick(
    '回收站中的所有照片都会被彻底删除，无法撤销；已同步的照片也会从云端删除。',
    'Every photo in trash is removed from disk and synced photos are also deleted from the cloud. This cannot be undone.',
  );
  String get actionFailed => pick('操作失败，请重试。', 'The action failed. Try again.');
  String trashedCount(int n) =>
      pick('已将 $n 项移到回收站', '$n item(s) moved to trash');
  String restoredCount(int n) => pick('已恢复 $n 项', '$n item(s) restored');
  String purgedCount(int n) => pick('已彻底删除 $n 项', '$n item(s) deleted');
  String addedToAlbumCount(int n) => pick('已添加 $n 项', '$n item(s) added');

  // --- Viewer extras ----------------------------------------------------
  String get rotateLeft => pick('向左旋转', 'Rotate left');
  String get rotateRight => pick('向右旋转', 'Rotate right');
  String get fullscreen => pick('全屏预览', 'Fullscreen preview');
  String get captureTime => pick('拍摄时间', 'Captured');
  String get mediaType => pick('类型', 'Type');
  String get state => pick('状态', 'State');
  String get trashed => pick('已删除', 'Trashed');
  String get active => pick('正常', 'Active');

  // --- Editing ----------------------------------------------------------
  String get edit => pick('编辑', 'Edit');
  String get editPhoto => pick('编辑照片', 'Edit photo');
  String get reset => pick('重置', 'Reset');
  String get saveCopy => pick('另存为副本', 'Save a copy');
  String get saveOverwrite => pick('覆盖原图', 'Overwrite original');
  String get rotation => pick('旋转', 'Rotation');
  String get crop => pick('裁剪', 'Crop');
  String get brightness => pick('亮度', 'Brightness');
  String get contrast => pick('对比度', 'Contrast');
  String get saturation => pick('饱和度', 'Saturation');
  String get noPendingEdits => pick('还没有修改', 'No changes yet');
  String get discardEditsTitle => pick('放弃未保存的修改？', 'Discard unsaved changes?');
  String get discardEditsBody => pick(
    '关闭编辑器会丢失当前调整。',
    'Closing the editor discards the current adjustments.',
  );
  String get discard => pick('放弃', 'Discard');
  String get continueEditing => pick('继续编辑', 'Keep editing');
  String get savedCopy => pick('已保存副本', 'Saved a copy');
  String get overwriting => pick('正在覆盖原图…', 'Overwriting the original…');
  String get saving => pick('正在保存…', 'Saving…');
  String get appliedEdits => pick('已应用修改', 'Changes applied');
  String get editorFailed => pick('保存失败，请重试。', 'Save failed. Try again.');

  // --- Cloud sync -------------------------------------------------------
  String get cloudSync => pick('云同步', 'Cloud Sync');
  String get cloudSyncBody => pick(
    '登录后下载云端照片并同步收藏。可在“上传范围”选择要自动上传的相册，也可在照片页手动上传。',
    'Sign in to download cloud photos and sync favorites. Choose albums under "Upload scope" for automatic uploads, or upload individual photos from the library.',
  );
  String get cloudEndpoint => pick('服务器地址', 'Server endpoint');
  String get cloudEndpointHint => 'http://127.0.0.1:8790';
  String get cloudUsername => pick('用户名', 'Username');
  String get cloudPassword => pick('密码', 'Password');
  String get cloudPasswordHint =>
      pick('仅用于登录，不会保存', 'Used only to sign in; never stored');
  String get cloudSignIn => pick('登录', 'Sign in');
  String get cloudSignOut => pick('退出登录', 'Sign out');
  String get cloudSyncNow => pick('立即同步', 'Sync now');
  String get cloudAutoSync => pick('自动同步', 'Auto sync');
  String get cloudAutoSyncHint => pick(
    '打开后立即同步一次；之后本地照片、收藏或相册发生变化时，停止变更 10 秒后自动同步；应用启动时也会同步。关闭时只在你点击“立即同步”时同步。',
    'Turning this on syncs once right away, again 10 seconds after local photos, favorites or albums change, and at each app start; when off, syncing only happens when you press "Sync now".',
  );
  String get cloudAutoSyncNeedsSignIn =>
      pick('登录后可开启自动同步。', 'Sign in to enable auto sync.');
  String get syncing => pick('同步中…', 'Syncing…');
  String get cloudSyncLive => pick('正在同步中…', 'Syncing…');
  String get cloudUploadLive => pick('正在上传中…', 'Uploading…');
  String cloudSyncLiveProgress(int done, int total) =>
      pick('正在同步中，已同步 $done/$total', 'Syncing… $done/$total synced');
  String cloudUploadLiveProgress(int done, int total) =>
      pick('正在上传中，已上传 $done/$total', 'Uploading… $done/$total uploaded');
  String cloudFavoriteLiveProgress(int done, int total) =>
      pick('正在同步更改，已同步 $done/$total', 'Syncing changes… $done/$total');
  String indexingProgress(int done, int total) =>
      pick('正在索引中 $done/$total', 'Indexing $done/$total');
  String indexedProgress(int done, int total) =>
      pick('已索引 $done/$total', 'Indexed $done/$total');
  String get indexingHint => pick(
    '正在读取本地照片并准备缩略图，完成后滚动浏览会更流畅。',
    'Preparing local photo thumbnails so browsing stays smooth.',
  );
  String indexingUnavailable(int count) =>
      pick('$count 项暂时不可用', '$count unavailable');
  String get indexingLimited => pick('部分项目暂时不可用', 'Some items unavailable');
  String get cloudSyncPreparing => pick('正在准备同步…', 'Preparing sync…');
  String get cloudSyncChecking => pick('正在检查云端更新…', 'Checking the cloud…');
  String get cloudSyncReceiving => pick('正在接收云端照片…', 'Receiving cloud photos…');
  String get cloudSyncUploading => pick('正在上传本地照片…', 'Uploading local photos…');
  String get cloudSyncFinalizing => pick('正在完成同步…', 'Finishing sync…');
  String get cloudSyncReady => pick('云同步已就绪', 'Cloud sync is ready');
  String get cloudSyncNeedsAttention => pick('需要处理', 'Needs attention');
  String cloudSyncPendingSummary(int uploads, int favorites) => pick(
    '待上传 $uploads 张照片，待同步收藏 $favorites 项',
    '$uploads photos wait to upload, $favorites favorites wait to sync',
  );
  String cloudSyncReceivingProgress(int done, int total) =>
      pick('已下载 $done / $total 张照片', 'Downloaded $done / $total photos');
  String cloudSyncUploadingProgress(int done, int total) =>
      pick('已上传 $done / $total 张照片', 'Uploaded $done / $total photos');
  String cloudSyncFavoriteProgress(int done, int total) =>
      pick('已同步收藏 $done / $total 项', 'Favorites $done / $total');
  String cloudUploadFailedCount(int count) => pick(
    '有 $count 张照片上传失败，可在照片页重新上传。',
    '$count photos failed to upload. Upload them again from the library.',
  );
  String cloudSyncSkipped(int count) => pick(
    '另有 $count 项已跳过，可在下次同步时重试。',
    '$count items were skipped and will be retried on the next sync.',
  );
  String cloudSyncIdleDetail(
    String lastSync,
    int uploads,
    int favorites,
  ) => pick(
    '上次同步：$lastSync · 待上传 $uploads 张 · 待同步收藏 $favorites 项',
    'Last sync: $lastSync · $uploads pending uploads · $favorites pending favorites',
  );
  String cloudSyncReadyDetail(int uploads, int favorites) => pick(
    '尚未同步 · 待上传 $uploads 张 · 待同步收藏 $favorites 项',
    'Not synced yet · $uploads pending uploads · $favorites pending favorites',
  );
  String cloudSyncFailedCounts(
    int downloaded,
    int uploaded,
    int failed,
    String reason,
  ) => pick(
    '同步未完成：下载 $downloaded，上传 $uploaded，失败 $failed。$reason',
    'Sync incomplete: $downloaded downloaded, $uploaded uploaded, $failed failed. $reason',
  );
  String get cloudLastSync => pick('上次同步', 'Last sync');
  String get cloudNeverSynced => pick('尚未同步', 'Not synced yet');
  String get cloudPendingUploads => pick('待上传', 'Pending uploads');
  String get cloudPendingFavorites => pick('待同步收藏', 'Pending favorites');
  String get cloudBoundCount => pick('云端照片', 'Cloud photos');
  String get cloudDataUsage => pick('云端数据', 'Cloud data');
  String get clearCacheTitle =>
      pick('清理缓存与云端数据？', 'Clear cache and cloud data?');
  String get clearCacheBody => pick(
    '将删除缩略图缓存、已下载的云端照片、云端会话与同步记录。\n'
        '你的本机照片不会被删除；云端照片之后可以重新下载。',
    'This removes the thumbnail cache, the downloaded cloud photos, the '
        'cloud session and the sync records.\n'
        'Your own photos are kept; the cloud photos can be downloaded again.',
  );
  String get cloudUnavailable =>
      pick('当前构建不支持云同步。', 'Cloud sync is unavailable in this build.');
  String get cloudSignedOut => pick(
    '云同步未登录，请先在设置中登录。',
    'Cloud sync is signed out. Sign in from Settings.',
  );
  String get cloudUpload => pick('上传到云端', 'Upload to cloud');
  String get cloudUploadQueued => pick('已加入上传队列', 'Added to the upload queue');
  String get cloudUploadNone => pick('没有可上传的照片', 'No photos to upload');
  String get cloudAccounts => pick('同步账号', 'Sync accounts');
  String get cloudCurrentAccount => pick('当前账号', 'Current account');
  String get cloudSwitchAccount => pick('切换账号', 'Switch account');
  String get cloudLoginOtherAccount =>
      pick('登录其他账号', 'Sign in to another account');
  String get cloudRemoveAccount => pick('移除账号', 'Remove account');
  String get cloudRemoveAccountTitle =>
      pick('移除这个同步账号？', 'Remove this sync account?');
  String cloudRemoveAccountBody(String username) => pick(
    '将移除 $username 的本地会话和同步记录，并保留本机照片与云端照片。',
    'This removes the local session and sync records of $username. Local and cloud photos are kept.',
  );
  String get cloudAccountSignedIn => pick('已登录', 'Signed in');
  String get cloudAccountNeedsLogin => pick('需要重新登录', 'Sign-in required');
  String get cloudNotSignedIn => pick('未登录', 'Not signed in');
  String get cloudSignInToSync =>
      pick('登录后开始同步云端照片。', 'Sign in to sync cloud photos.');
  String get cloudAccountRemoved => pick('账号已移除', 'Account removed');
  String get cloudAccountSingleHint => pick(
    '同一时间只同步一个账号。切换后各账号的配置与同步进度分别保留。',
    'Only one account syncs at a time. Each account keeps its own settings and progress.',
  );
  String get cloudUploadScope => pick('上传范围', 'Upload scope');
  String get cloudUploadScopeNone => pick('仅接收云端照片', 'Receive only');
  String get cloudUploadScopeAll => pick('上传所有相册', 'Upload all albums');
  String cloudUploadScopeSelected(int count) =>
      pick('已选择 $count 个相册上传', '$count albums selected for upload');
  String get cloudUploadScopeHint => pick(
    '每次同步会自动上传所选相册中尚未同步的照片；空选择表示只接收。照片页的手动上传始终可用。',
    'Each sync uploads unsynced photos in the selected albums; an empty selection means receive only. Manual upload from the library stays available.',
  );
  String get cloudChooseAlbums => pick('选择相册', 'Choose albums');
  String get cloudUploadScopeTitle => pick('选择上传相册', 'Choose upload albums');
  String get cloudUploadScopeReceiveOnly =>
      pick('仅接收（不上传）', 'Receive only (no uploads)');
  String get cloudUploadScopeSelectedOption => pick('指定相册', 'Selected albums');
  String get cloudUploadScopeAllOption => pick('全部相册', 'All albums');
  String get cloudUploadScopeEmpty =>
      pick('没有可选择的本地相册。', 'There are no local albums to choose.');
  String get cloudUploadScopeApplied => pick(
    '上传范围已保存，下次同步生效。',
    'Upload scope saved. It applies on the next sync.',
  );
  String cloudUploadResult(int queued, int skipped, int rejected) => pick(
    '已加入 $queued 张，跳过 $skipped 张，无法上传 $rejected 张',
    '$queued queued, $skipped skipped, $rejected rejected',
  );
  String cloudSyncedCounts(int downloaded, int uploaded, int favorites) => pick(
    '同步完成：下载 $downloaded，上传 $uploaded，收藏 $favorites',
    'Synced: $downloaded downloaded, $uploaded uploaded, $favorites favorites',
  );

  /// A short state title; [cloudError] remains the explanatory sentence.
  String cloudErrorHeadline(String code) => switch (code) {
    'AuthFailed' || 'TokenExpired' => pick('云同步登录已失效', 'Cloud sign-in expired'),
    'Network' => pick('网络不可用', 'Network unavailable'),
    'EndpointRejected' => pick('服务器地址无效', 'Invalid server address'),
    'AccountExists' => pick('账号身份不一致', 'Account identity changed'),
    'AccountNotFound' => pick('账号不存在', 'Account not found'),
    'CloudScopeChanged' => pick('云端图库身份已变化', 'Cloud library identity changed'),
    'AdminAccountUnsupported' => pick('不支持管理员账号', 'Administrator account'),
    'LeaseBusy' => pick('另一台设备正在同步', 'Another device is syncing'),
    'LeaseLost' => pick('同步写入权已失效', 'Sync lease lost'),
    'NotCurrent' => pick('云端数据已变化', 'Cloud data changed'),
    'QuotaExceeded' => pick('云端空间不足', 'Cloud storage is full'),
    'SourceChanged' => pick('照片已发生变化', 'A photo changed'),
    'ThumbnailFailed' => pick('缩略图处理失败', 'Thumbnail failed'),
    'UnsupportedMedia' => pick('存在不支持的媒体格式', 'Unsupported media'),
    'GraphInvalid' ||
    'ChangeFailed' => pick('云端数据不完整', 'Cloud data is incomplete'),
    _ => pick('云同步失败', 'Cloud sync failed'),
  };

  String cloudError(String code) => switch (code) {
    'AuthFailed' => pick(
      '登录失败，请检查服务器地址、用户名和密码。',
      'Sign-in failed. Check the endpoint, username and password.',
    ),
    'TokenExpired' => pick(
      '登录已过期，请重新登录。',
      'The session expired. Sign in again.',
    ),
    'Network' => pick(
      '无法连接服务器，请检查网络后重试。',
      'Cannot reach the server. Check the connection and retry.',
    ),
    'EndpointRejected' => pick(
      '服务器地址无效：请使用完整地址，例如 http://127.0.0.1:8790，不要使用 localhost。',
      'Invalid endpoint. Use a full address such as http://127.0.0.1:8790, not localhost.',
    ),
    'AccountExists' => pick(
      '服务器返回的账号身份与已保存的账号不一致，请检查服务器地址与用户名。',
      'The server returned a different account identity. Check the endpoint and username.',
    ),
    'AccountNotFound' => pick(
      '该账号已不存在，请选择其他账号或重新登录。',
      'That account no longer exists. Choose another account or sign in again.',
    ),
    'InvalidUploadScope' => pick(
      '上传范围无效，请重新选择相册。',
      'The upload scope is invalid. Choose the albums again.',
    ),
    'CloudScopeChanged' => pick(
      '云端图库身份已变化，已停止同步以保护现有照片。',
      'The cloud library identity changed. Sync stopped to protect existing photos.',
    ),
    'AdminAccountUnsupported' => pick(
      '不支持管理员账号，请使用普通用户。',
      'Administrator accounts are not supported. Use a regular user.',
    ),
    'LeaseBusy' => pick(
      '另一台设备正在同步，请稍后再试。',
      'Another device is syncing. Try again shortly.',
    ),
    'LeaseLost' => pick('同步写入权已失效，请重试。', 'The sync lease was lost. Try again.'),
    'NotCurrent' => pick(
      '云端数据已变化，请再同步一次。',
      'Cloud data changed. Sync once more.',
    ),
    'GraphInvalid' => pick(
      '云端照片数据不完整，已保留现有内容。',
      'Cloud photo data is incomplete; existing content was kept.',
    ),
    'ChangeFailed' => pick(
      '部分云端变更无法读取，已保留现有内容。',
      'Some cloud changes could not be read; existing content was kept.',
    ),
    'UnsupportedMedia' => pick(
      '云端照片格式不受支持，已跳过下载。',
      'A cloud photo format is unsupported and was skipped.',
    ),
    'ThumbnailFailed' => pick(
      '无法生成上传缩略图。',
      'Could not create an upload thumbnail.',
    ),
    'QuotaExceeded' => pick('云端存储空间不足。', 'The cloud storage quota is full.'),
    'SourceChanged' => pick(
      '照片在上传前发生了变化，请重新选择。',
      'The photo changed before upload. Select it again.',
    ),
    'LibraryClosed' => pick(
      '图库已关闭，请重新打开。',
      'The library was closed. Open it again.',
    ),
    'ServerRejected' => pick(
      '服务器拒绝了请求，请稍后重试。',
      'The server rejected the request. Try again later.',
    ),
    _ => pick('云同步失败，请重试。', 'Cloud sync failed. Try again.'),
  };

  String libraryError(String kind) => switch (kind) {
    'picker' => pick(
      '无法打开文件选择器，请重试。',
      'The file picker could not open. Try again.',
    ),
    'cancel' => pick(
      '停止扫描请求失败，扫描仍在进行，可以重试。',
      'The stop request failed. The scan is still running; try again.',
    ),
    'scan' => pick(
      '扫描未完成。请检查文件访问权限，然后重试添加。',
      'The scan did not finish. Check file access and try adding again.',
    ),
    'favorite' => pick(
      '收藏修改未保存，请重试。',
      'The favorite change was not saved. Try again.',
    ),
    'events' => pick(
      '照片更新通知已中断，请刷新。',
      'Photo updates stopped. Refresh to reconnect.',
    ),
    'nextPage' => pick('无法读取这一页，请重试。', 'This page could not load. Try again.'),
    _ => pick('无法读取本地照片，请重试。', 'The photos could not load. Try again.'),
  };
}
