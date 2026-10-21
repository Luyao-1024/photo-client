import 'package:flutter/widgets.dart';

/// Presentation copy catalog. Platform exceptions never become user-facing copy.
class AppStrings {
  AppStrings(Locale locale) : chinese = locale.languageCode == 'zh';
  final bool chinese;
  static AppStrings of(BuildContext context) =>
      AppStrings(Localizations.localeOf(context));
  String pick(String zh, String en) => chinese ? zh : en;

  String get appTitle => 'PhotoViewer';
  String get library => pick('图库', 'Library');
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
  String get emptyLibrary => pick('图库为空', 'Library is empty');
  String get openSettings => pick('打开设置', 'Open settings');
  String get scanFolders => pick('扫描目录', 'Scan folders');
  String photosCountLabel(int n) => pick('$n 张照片', '$n photos');
  String positionLabel(int cur, int total) => '$cur / $total';
  String get libraryFailed => pick('图库加载失败', 'Library failed to load');
  String get libraryFailedBody => pick(
    '无法打开本地图库。请重试；如果一直失败，请确认照片所在目录仍然可用。',
    'The local library could not be opened. Try again; if it keeps failing, check that your photo folders are still available.',
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
  String get glassOn => pick('开启', 'On');
  String get glassOff => pick('纯色', 'Solid');
  String get glassHint => pick(
    '仅工具栏使用裁切模糊；高对比度或系统关闭动效时使用纯色。',
    'Only the toolbar uses clipped blur. High contrast or disabled system animations uses solid surfaces.',
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
  String get refresh => pick('刷新图库', 'Refresh library');
  String get loadingLibrary => pick('正在读取本地图库…', 'Loading the local library…');
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
    '图库已更新，返回后可继续浏览',
    'The library changed. Return to continue browsing.',
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
    '此操作无法撤销，文件将从磁盘删除。',
    'This cannot be undone. The files are removed from disk.',
  );
  String get confirmEmptyTrashTitle => pick('清空回收站？', 'Empty trash?');
  String get confirmEmptyTrashBody => pick(
    '回收站中的所有照片都会被彻底删除，无法撤销。',
    'Every photo in trash is removed from disk. This cannot be undone.',
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
      '图库更新通知已中断，请刷新。',
      'Library updates stopped. Refresh to reconnect.',
    ),
    'nextPage' => pick('无法读取这一页，请重试。', 'This page could not load. Try again.'),
    _ => pick('无法读取本地图库，请重试。', 'The local library could not load. Try again.'),
  };
}
