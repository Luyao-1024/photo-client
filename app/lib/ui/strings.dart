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
  String get connection => pick('核心连接', 'Core connection');
  String get settings => pick('外观', 'Appearance');
  String get stage => pick('S01 · 工程验证', 'S01 · Foundation');
  String get connecting => pick('正在连接本地核心…', 'Connecting to the local core…');
  String get ready => pick('本地核心已连接', 'Local core connected');
  String get failed => pick('本地核心连接中断', 'Local core unavailable');
  String get stopped => pick('本地核心已停止', 'Local core stopped');
  String get retry => pick('重试连接', 'Retry connection');
  String get emptyTitle => pick('本地图库从这里开始', 'Your local library starts here');
  String get emptyBody => pick(
    '后续可通过导入本地文件或目录建立图库。当前 S01 仅验证本地核心连接，尚未提供照片导入和浏览。',
    'Your library will use photos imported from local files or folders. This S01 preview verifies the local core connection; photo import and browsing are not available yet.',
  );
  String get openConnection => pick('查看核心连接', 'Inspect core connection');
  String get foundationHint =>
      pick('本次预览尚未读取照片', 'This preview has not loaded any photos');
  String get connectionBody => pick(
    '这里展示当前核心会话的真实信息。连接成功仅代表本地桥接可用。',
    'These details come from the current core session. A connection verifies the local bridge only.',
  );
  String get initializeError => pick(
    '无法初始化本地核心。请检查启动配置和本地运行环境，然后重试。',
    'The local core could not initialize. Check the launch configuration and local runtime, then retry.',
  );
  String get streamError => pick(
    '运行时事件订阅已中断，当前状态可能过期。请重新连接。',
    'The runtime event stream ended. Its state may be stale; reconnect to continue.',
  );
  String get probeError =>
      pick('往返调用失败，可以再次尝试。', 'The round trip failed. You can try again.');
  String get shutdownError =>
      pick('核心未确认正常关闭。', 'The core did not confirm a clean shutdown.');
  String get profile => pick('平台配置', 'Platform profile');
  String get digest => pick('配置摘要', 'Profile digest');
  String get protocol => pick('桥接协议', 'Bridge protocol');
  String get session => pick('会话 ID', 'Session ID');
  String get event => pick('最新事件序号', 'Latest event sequence');
  String get waitingEvent => pick('等待事件', 'Waiting for an event');
  String get runtimeStatus => pick('运行时状态码', 'Runtime status code');
  String get probe => pick('验证往返调用', 'Verify round trip');
  String get probing => pick('正在验证…', 'Verifying…');
  String get reply => pick('核心返回', 'Core reply');
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
