import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'cloud_sync_settings_page.dart';
import 'glass_dialog.dart';
import 'glass_theme.dart';
import 'local_library_controller.dart';
import 'presentation_preferences.dart';
import 'strings.dart';

class LocalSettingsDialog extends ConsumerStatefulWidget {
  const LocalSettingsDialog({super.key, required this.onShortcuts});
  final VoidCallback onShortcuts;
  @override
  ConsumerState<LocalSettingsDialog> createState() =>
      _LocalSettingsDialogState();
}

class _LocalSettingsDialogState extends ConsumerState<LocalSettingsDialog> {
  int _category = 0;
  List<dynamic> _sources = [];
  int? _usage;
  bool _busy = false, _failed = false;
  @override
  void initState() {
    super.initState();
    scheduleMicrotask(_reload);
  }

  Future<void> _reload() async {
    try {
      final controller = ref.read(localLibraryProvider.notifier);
      final sources = await controller.localCommand({'op': 'sources'}) as List?;
      final usage = await controller.localCommand({'op': 'cacheUsage'}) as int?;
      if (mounted) {
        setState(() {
          _sources = sources ?? [];
          _usage = usage;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await _reload();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(Map source) async {
    final strings = AppStrings.of(context);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => GlassAlertDialog(
        title: Text(strings.pick('移除来源？', 'Remove source?')),
        content: Text(
          strings.pick(
            '仅从图库移除此来源的索引，原始文件会保留。',
            'Remove this source from the library. Original files are kept.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(strings.cancel),
          ),
          TextButton(
            key: const ValueKey('remove-source-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(strings.pick('移除来源', 'Remove source')),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    await _run(() async {
      final controller = ref.read(localLibraryProvider.notifier);
      await controller.localCommand({'op': 'removeSource', 'id': source['id']});
      await controller.refresh(force: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final preferences = ref.watch(presentationProvider);
    final controller = ref.read(presentationProvider.notifier);
    final categories = [
      strings.pick('通用', 'General'),
      strings.pick('外观', 'Appearance'),
      strings.pick('照片与视频', 'Photos and Videos'),
      strings.pick('存储与日志', 'Storage and Logs'),
      strings.cloudSync,
    ];
    final titles = [
      strings.pick('通用设置', 'General'),
      strings.pick('外观设置', 'Appearance'),
      strings.pick('照片与视频', 'Photos and Videos'),
      strings.pick('存储与日志', 'Storage and Logs'),
      strings.cloudSync,
    ];
    Widget section(String title, List<Widget> children) => Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: GlassSection(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
    final pages = <Widget>[
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          section(strings.language, [
            Wrap(
              spacing: 8,
              children: [
                for (final (entry, label) in [
                  (const Locale('zh', 'CN'), '简体中文'),
                  (const Locale('en'), 'English'),
                ])
                  ChoiceChip(
                    key: ValueKey(
                      'settings-language-${entry.languageCode == 'zh' ? 'zh' : 'en'}',
                    ),
                    label: Text(label),
                    selected:
                        Localizations.localeOf(context).languageCode ==
                        entry.languageCode,
                    onSelected: (_) => controller.setLocale(entry),
                  ),
              ],
            ),
          ]),
          section(strings.keyboardShortcuts, [
            ListTile(
              contentPadding: EdgeInsets.zero,
              key: const ValueKey('settings-shortcuts'),
              leading: const Icon(Icons.keyboard_outlined),
              title: Text(strings.keyboardShortcuts),
              trailing: const Icon(Icons.chevron_right),
              onTap: widget.onShortcuts,
            ),
          ]),
          section(strings.theme, [
            Wrap(
              spacing: 8,
              children: [
                for (final (mode, label) in [
                  (ThemeMode.system, strings.system),
                  (ThemeMode.light, strings.light),
                  (ThemeMode.dark, strings.dark),
                ])
                  ChoiceChip(
                    key: ValueKey('settings-theme-${mode.name}'),
                    label: Text(label),
                    selected: preferences.themeMode == mode,
                    onSelected: (_) => controller.setTheme(mode),
                  ),
              ],
            ),
          ]),
          section(strings.pick('辅助功能', 'Accessibility'), [
            SwitchListTile(
              key: const ValueKey('settings-reduce-motion'),
              contentPadding: EdgeInsets.zero,
              title: Text(strings.pick('减少动画', 'Reduce motion')),
              value: preferences.reduceMotion,
              onChanged: controller.setReduceMotion,
            ),
          ]),
        ],
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          section(strings.pick('透明度', 'Transparency'), [
            Slider(
              key: const ValueKey('settings-transparency'),
              value: preferences.transparency,
              divisions: 100,
              label: '${(preferences.transparency * 100).round()}%',
              onChanged: controller.setTransparency,
            ),
          ]),
          section(strings.pick('背景虚化程度', 'Background blur'), [
            Slider(
              key: const ValueKey('settings-background-blur'),
              value: preferences.backgroundBlur,
              divisions: 100,
              label: '${(preferences.backgroundBlur * 100).round()}%',
              onChanged: controller.setBackgroundBlur,
            ),
          ]),
          section(strings.pick('跟随滚动', 'Follow scrolling'), [
            SwitchListTile(
              key: const ValueKey('settings-follow-scroll'),
              contentPadding: EdgeInsets.zero,
              title: Text(strings.pick('背景跟随滚动', 'Follow scrolling')),
              subtitle: Text(
                strings.pick('关闭后使用相册封面', 'Use the album cover when off'),
              ),
              value: preferences.followScroll,
              onChanged: controller.setFollowScroll,
            ),
          ]),
        ],
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          section(strings.pick('照片网格', 'Photos grid'), [
            Text(
              strings.pick(
                '日视图：${preferences.dayColumns} 列',
                'Day view: ${preferences.dayColumns} columns',
              ),
            ),
            Slider(
              key: const ValueKey('settings-day-columns'),
              value: preferences.dayColumns.toDouble(),
              min: 3,
              max: 8,
              divisions: 5,
              label: '${preferences.dayColumns}',
              onChanged: (value) => controller.setDayColumns(value.round()),
            ),
            DropdownButtonFormField<String>(
              key: const ValueKey('settings-order'),
              isExpanded: true,
              initialValue: preferences.order,
              decoration: InputDecoration(
                labelText: strings.pick('排序', 'Sort'),
              ),
              items: [
                for (final (value, label) in [
                  ('date_desc', strings.pick('日期：从新到旧', 'Date: newest first')),
                  ('date_asc', strings.pick('日期：从旧到新', 'Date: oldest first')),
                  ('name_asc', strings.pick('名称：升序', 'Name: ascending')),
                  ('name_desc', strings.pick('名称：降序', 'Name: descending')),
                ])
                  DropdownMenuItem(value: value, child: Text(label)),
              ],
              onChanged: (value) {
                if (value != null) controller.setOrder(value);
              },
            ),
          ]),
          section(strings.pick('动态照片', 'Motion photos'), [
            SwitchListTile(
              key: const ValueKey('settings-auto-play-motion'),
              contentPadding: EdgeInsets.zero,
              title: Text(strings.pick('立即播放动态照片', 'Play motion photos automatically')),
              subtitle: Text(
                strings.pick(
                  '打开动态照片时直接播放动态片段',
                  'Play the motion clip as soon as a dynamic photo opens',
                ),
              ),
              value: preferences.autoPlayMotionPhoto,
              onChanged: controller.setAutoPlayMotionPhoto,
            ),
          ]),
          section(strings.pick('照片来源', 'Sources'), [            Consumer(
              builder: (context, ref, _) {
                final picker = ref.watch(sourcePickerProvider);
                final state = ref.watch(localLibraryProvider);
                final library = ref.read(localLibraryProvider.notifier);
                final busy = _busy || state.scanning || state.selecting;
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      key: const ValueKey('add-folder'),
                      onPressed: picker == null || busy
                          ? null
                          : () => _run(
                              () => library.importSources(
                                picker,
                                directory: true,
                              ),
                            ),
                      icon: const Icon(Icons.create_new_folder_outlined),
                      label: Text(strings.addFolder),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('add-files'),
                      onPressed: picker == null || busy
                          ? null
                          : () => _run(
                              () => library.importSources(
                                picker,
                                directory: false,
                              ),
                            ),
                      icon: const Icon(Icons.note_add_outlined),
                      label: Text(strings.addFiles),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('settings-rescan'),
                      onPressed: busy
                          ? null
                          : () => _run(library.rescanSources),
                      icon: const Icon(Icons.refresh),
                      label: Text(strings.pick('重新扫描', 'Rescan')),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 8),
            for (final source in _sources)
              if ((source as Map)['enabled'] == true &&
                  source['kind'] != 'managed')
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    source['path'] as String,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    source['availability'] == 'available'
                        ? strings.pick('可用', 'Available')
                        : strings.pick(
                            '来源不可用，请检查连接或权限',
                            'Unavailable. Check the connection or permissions.',
                          ),
                  ),
                  trailing: IconButton(
                    key: ValueKey('settings-remove-source-${source['path']}'),
                    tooltip: strings.pick(
                      '移除来源，保留原文件',
                      'Remove source and keep files',
                    ),
                    onPressed: _busy ? null : () => _remove(source),
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                ),
          ]),
        ],
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          section(strings.pick('缩略图', 'Thumbnails'), [
            DropdownButtonFormField<int>(
              key: const ValueKey('settings-thumbnail-workers'),
              isExpanded: true,
              initialValue: preferences.thumbnailWorkers,
              decoration: InputDecoration(
                labelText: strings.pick(
                  '生成速度（下次启动生效）',
                  'Generation speed (next launch)',
                ),
              ),
              items: [
                for (final (value, label) in [
                  (1, strings.pick('标准', 'Standard')),
                  (2, strings.pick('快速', 'Fast')),
                  (4, strings.pick('最快', 'Fastest')),
                ])
                  DropdownMenuItem(value: value, child: Text(label)),
              ],
              onChanged: (value) {
                if (value != null) controller.setThumbnailWorkers(value);
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(strings.pick('缩略图缓存', 'Thumbnail cache')),
              subtitle: Text(
                _usage == null
                    ? strings.pick('正在计算…', 'Calculating…')
                    : '${(_usage! / 1024 / 1024).toStringAsFixed(1)} MB',
              ),
              trailing: TextButton(
                key: const ValueKey('settings-clear-cache'),
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        await ref
                            .read(localLibraryProvider.notifier)
                            .localCommand({'op': 'clearCache'});
                      }),
                child: Text(strings.pick('清理', 'Clear')),
              ),
            ),
          ]),
          section(strings.pick('日志', 'Logs'), [
            DropdownButtonFormField<String>(
              key: const ValueKey('settings-log-level'),
              isExpanded: true,
              initialValue: preferences.logLevel,
              decoration: InputDecoration(
                labelText: strings.pick('日志级别', 'Logging level'),
              ),
              items: [
                for (final level in ['error', 'warn', 'info', 'debug'])
                  DropdownMenuItem(value: level, child: Text(level)),
              ],
              onChanged: (value) {
                if (value != null) controller.setLogLevel(value);
              },
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              key: const ValueKey('settings-clear-logs'),
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      await ref
                          .read(localLibraryProvider.notifier)
                          .localCommand({'op': 'clearLogs'});
                    }),
              child: Text(strings.pick('清理日志', 'Clear logs')),
            ),
          ]),
        ],
      ),
      const CloudSyncSettingsPage(),
    ];
    return GlassDialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 720),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      strings.settings,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('settings-close'),
                    tooltip: strings.close,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            if (_failed || preferences.saveFailed)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        strings.pick(
                          '设置读取或保存失败，请重试。',
                          'Could not read or save settings. Please retry.',
                        ),
                      ),
                    ),
                    TextButton(onPressed: _reload, child: Text(strings.retry)),
                  ],
                ),
              ),
            Flexible(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 600;
                  final content = SingleChildScrollView(
                    key: const ValueKey('settings-content'),
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          titles[_category],
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 24),
                        pages[_category],
                      ],
                    ),
                  );
                  final navigation = compact
                      ? SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (var i = 0; i < categories.length; i++)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                  ),
                                  child: ChoiceChip(
                                    key: ValueKey('settings-category-$i'),
                                    label: Text(categories[i]),
                                    selected: _category == i,
                                    onSelected: (_) =>
                                        setState(() => _category = i),
                                  ),
                                ),
                            ],
                          ),
                        )
                      : SizedBox(
                          width: 180,
                          child: Material(
                            color: GlassTheme.of(context).inset,
                            child: ListView(
                              padding: const EdgeInsets.all(12),
                              children: [
                                for (var i = 0; i < categories.length; i++)
                                  ListTile(
                                    key: ValueKey('settings-category-$i'),
                                    title: Text(categories[i]),
                                    selected: _category == i,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    onTap: () => setState(() => _category = i),
                                  ),
                              ],
                            ),
                          ),
                        );
                  return compact
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            navigation,
                            Flexible(child: content),
                          ],
                        )
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            navigation,
                            const VerticalDivider(width: 1),
                            Expanded(child: content),
                          ],
                        );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
