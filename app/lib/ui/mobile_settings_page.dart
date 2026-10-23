import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'cloud_sync_controller.dart';
import 'local_settings_dialog.dart';
import 'mobile_settings_surface.dart';
import 'presentation_preferences.dart';
import 'strings.dart';

class MobileSettingsPage extends ConsumerWidget {
  const MobileSettingsPage({super.key});

  Future<void> _choose<T>(
    BuildContext context, {
    required String title,
    required T value,
    required List<(T, String)> choices,
    required ValueChanged<T> onChanged,
  }) async {
    final selected = await showModalBottomSheet<T>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: mobileSettingsCardColor(context),
      builder: (context) => Theme(
        data: mobileSettingsTheme(context),
        child: SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .75,
            ),
            child: ListView(
              key: const ValueKey('mobile-setting-choices'),
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                for (final (entry, label) in choices)
                  ListTile(
                    key: ValueKey('mobile-setting-choice-$entry'),
                    title: Text(label),
                    selected: entry == value,
                    trailing: entry == value ? const Icon(Icons.check) : null,
                    onTap: () => Navigator.of(context).pop(entry),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (context.mounted && selected != null) onChanged(selected);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = AppStrings.of(context);
    final preferences = ref.watch(presentationProvider);
    final controller = ref.read(presentationProvider.notifier);
    final cloud = ref.watch(cloudSyncProvider);
    final themes = [
      (ThemeMode.system, strings.system),
      (ThemeMode.light, strings.light),
      (ThemeMode.dark, strings.dark),
    ];
    final orders = [
      ('date_desc', strings.pick('最新照片在上方', 'Newest first')),
      ('date_asc', strings.pick('最早照片在上方', 'Oldest first')),
      ('name_asc', strings.pick('名称升序', 'Name ascending')),
      ('name_desc', strings.pick('名称降序', 'Name descending')),
    ];
    final languages = [('zh', '简体中文'), ('en', 'English')];
    final language = Localizations.localeOf(context).languageCode;
    void open(MobileSettingsCategory category) => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LocalSettingsDialog(mobileCategory: category),
      ),
    );
    Widget row(String key, String title, VoidCallback onTap, {String? value}) =>
        _SettingsRow(
          key: ValueKey(key),
          title: title,
          value: value,
          onTap: onTap,
        );

    Widget card(Widget child, {String? hint}) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: mobileSettingsCardColor(context),
            borderRadius: BorderRadius.circular(24),
            clipBehavior: Clip.antiAlias,
            child: child,
          ),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
              child: Text(
                hint,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
    return Theme(
      data: mobileSettingsTheme(context),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        child: Scaffold(
          key: const ValueKey('mobile-settings-page'),
          backgroundColor: mobileSettingsBackground(context),
          body: SafeArea(
            top: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          strings.settings,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('mobile-settings-close'),
                        tooltip: strings.close,
                        onPressed: () => Navigator.of(context).pop(),
                        style: IconButton.styleFrom(
                          backgroundColor: mobileSettingsCardColor(context)
                              .withValues(alpha: .7),
                          shape: const CircleBorder(),
                        ),
                        icon: const Icon(Icons.close, size: 22),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    key: const PageStorageKey('mobile-settings-scroll'),
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    children: [
                      if (preferences.saveFailed)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            strings.pick(
                              '设置保存失败，请重试。',
                              'Could not save settings. Please retry.',
                            ),
                          ),
                        ),
                      card(
                        ListTile(
                          key: const ValueKey('mobile-settings-cloud'),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          leading: CircleAvatar(
                            radius: 22,
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: .18),
                            child: const Icon(
                              Icons.person,
                              size: 30,
                              color: Colors.white,
                            ),
                          ),
                          title: Text(
                            cloud.status.username ??
                                strings.pick('登录云端账号', 'Sign in to cloud'),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            cloud.loggedIn
                                ? strings.pick(
                                    '管理账号与照片同步',
                                    'Manage your account and photo sync',
                                  )
                                : strings.pick(
                                    '登录后开启云端照片同步',
                                    'Sign in to sync your photos',
                                  ),
                          ),
                          trailing: Icon(
                            Icons.chevron_right,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                          onTap: () => open(MobileSettingsCategory.cloud),
                        ),
                      ),
                      card(
                        row(
                          'mobile-settings-sync',
                          strings.pick('图库数据同步', 'Library sync'),
                          () => open(MobileSettingsCategory.cloud),
                          value: cloud.autoSync && cloud.loggedIn
                              ? strings.pick('已开启', 'On')
                              : strings.pick('关闭', 'Off'),
                        ),
                      ),
                      card(
                        row(
                          'settings-order',
                          strings.pick('照片排序', 'Photo order'),
                          () => _choose(
                            context,
                            title: strings.pick('照片排序', 'Photo order'),
                            value: preferences.order,
                            choices: orders,
                            onChanged: controller.setOrder,
                          ),
                          value: orders
                              .firstWhere(
                                (entry) => entry.$1 == preferences.order,
                                orElse: () => orders.first,
                              )
                              .$2,
                        ),
                      ),
                      card(
                        row(
                          'settings-theme',
                          strings.pick('显示模式', 'Display mode'),
                          () => _choose(
                            context,
                            title: strings.pick('显示模式', 'Display mode'),
                            value: preferences.themeMode,
                            choices: themes,
                            onChanged: controller.setTheme,
                          ),
                          value: themes
                              .firstWhere(
                                (entry) => entry.$1 == preferences.themeMode,
                              )
                              .$2,
                        ),
                      ),
                      card(
                        SwitchListTile(
                          key: const ValueKey('settings-auto-play-motion'),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                          ),
                          title: Text(
                            strings.pick('自动播放动态照片', 'Auto-play motion photos'),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          value: preferences.autoPlayMotionPhoto,
                          onChanged: controller.setAutoPlayMotionPhoto,
                        ),
                        hint: strings.pick(
                          '打开动态照片时自动播放动态片段',
                          'Play the motion clip when a dynamic photo opens',
                        ),
                      ),
                      card(
                        row(
                          'settings-day-columns',
                          strings.pick('日视图照片大小', 'Day view photo size'),
                          () => _choose(
                            context,
                            title: strings.pick('日视图列数', 'Day view columns'),
                            value: preferences.dayColumns,
                            choices: [
                              for (var i = 3; i <= 8; i++)
                                (i, strings.pick('$i 列', '$i columns')),
                            ],
                            onChanged: controller.setDayColumns,
                          ),
                          value: strings.pick(
                            '${preferences.dayColumns} 列',
                            '${preferences.dayColumns} columns',
                          ),
                        ),
                        hint: strings.pick(
                          '月视图与年视图会显示更密集的缩略图',
                          'Month and year views fit more thumbnails on screen',
                        ),
                      ),
                      card(
                        row(
                          'settings-language',
                          strings.language,
                          () => _choose(
                            context,
                            title: strings.language,
                            value: language,
                            choices: languages,
                            onChanged: (value) =>
                                controller.setLocale(Locale(value)),
                          ),
                          value: language == 'zh' ? '简体中文' : 'English',
                        ),
                      ),
                      card(
                        row(
                          'mobile-settings-appearance',
                          strings.pick('外观效果', 'Appearance effects'),
                          () => open(MobileSettingsCategory.appearance),
                        ),
                      ),
                      card(
                        SwitchListTile(
                          key: const ValueKey('settings-reduce-motion'),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                          ),
                          title: Text(
                            strings.pick('减少动画', 'Reduce motion'),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          value: preferences.reduceMotion,
                          onChanged: controller.setReduceMotion,
                        ),
                      ),
                      const SizedBox(height: 8),
                      card(
                        row(
                          'mobile-settings-sources',
                          strings.pick('照片来源', 'Photo sources'),
                          () => open(MobileSettingsCategory.sources),
                        ),
                      ),
                      card(
                        row(
                          'mobile-settings-storage',
                          strings.pick('存储与日志', 'Storage and logs'),
                          () => open(MobileSettingsCategory.storage),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    super.key,
    required this.title,
    required this.onTap,
    this.value,
  });
  final String title;
  final String? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 64),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.bodyLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            if (value != null) ...[
              const SizedBox(width: 12),
              Flexible(
                fit: FlexFit.tight,
                child: Text(
                  value!,
                  textAlign: TextAlign.end,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, size: 20),
          ],
        ),
      ),
    ),
  );
}
