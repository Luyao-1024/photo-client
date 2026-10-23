import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/cloud_sync_gateway.dart';
import '../services/local_library_gateway.dart';
import 'cloud_sync_controller.dart';
import 'glass_dialog.dart';
import 'glass_theme.dart';
import 'local_library_controller.dart';
import 'strings.dart';

/// Cloud account and manual sync controls embedded in the settings dialog.
class CloudSyncSettingsPage extends ConsumerStatefulWidget {
  const CloudSyncSettingsPage({super.key});

  @override
  ConsumerState<CloudSyncSettingsPage> createState() =>
      _CloudSyncSettingsPageState();
}

class _CloudSyncSettingsPageState extends ConsumerState<CloudSyncSettingsPage> {
  final _endpoint = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  ProviderSubscription<CloudSyncState>? _subscription;
  bool _addingAccount = false;
  bool _signInExpanded = false;
  String? _shownAccountId;

  @override
  void initState() {
    super.initState();
    _fillAccountFields(ref.read(cloudSyncProvider).status);
    _subscription = ref.listenManual<CloudSyncState>(cloudSyncProvider, (
      previous,
      next,
    ) {
      if (!mounted) return;
      if (!_addingAccount && next.status.accountId != _shownAccountId) {
        _fillAccountFields(next.status);
      }
    });
  }

  void _fillAccountFields(CloudStatus status) {
    _shownAccountId = status.accountId;
    _endpoint.text = status.endpoint ?? '';
    _username.text = status.username ?? '';
  }

  @override
  void dispose() {
    _subscription?.close();
    _endpoint.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final endpoint = _endpoint.text.trim();
    final username = _username.text.trim();
    final password = _password.text;
    if (endpoint.isEmpty || username.isEmpty || password.isEmpty) return;
    final code = await ref
        .read(cloudSyncProvider.notifier)
        .login(endpoint: endpoint, username: username, password: password);
    _password.clear();
    if (!mounted || code != null) return;
    setState(() {
      _addingAccount = false;
      _signInExpanded = false;
    });
  }

  void _expandSignIn() {
    setState(() {
      _addingAccount = false;
      _signInExpanded = true;
    });
  }

  void _collapseSignIn() {
    setState(() {
      _addingAccount = false;
      _signInExpanded = false;
    });
  }

  Future<void> _logout() async {
    await ref.read(cloudSyncProvider.notifier).logout();
    if (!mounted) return;
    setState(() {
      _addingAccount = false;
      _signInExpanded = false;
    });
  }

  Future<void> _syncNow() async {
    final report = await ref.read(cloudSyncProvider.notifier).syncNow();
    if (report == null || !mounted) return;
    final strings = AppStrings.of(context);
    // A full-width toast sits over the sidebar's bottom rows and swallows the
    // clicks on the settings entry for the seconds it lives. Keep it in the
    // middle of the window and off the side navigation.
    final width = MediaQuery.sizeOf(context).width;
    final side = width < 392 ? 16.0 : (width - 360) / 2;
    final code =
        report.errorCode ?? ref.read(cloudSyncProvider).status.errorCode;
    final message = report.failed > 0
        ? strings.cloudSyncFailedCounts(
            report.downloaded,
            report.uploaded,
            report.failed,
            code == null ? '' : strings.cloudError(code),
          )
        : strings.cloudSyncedCounts(
            report.downloaded,
            report.uploaded,
            report.favoritesApplied + report.favoritesUploaded,
          );
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          persist: false,
          margin: EdgeInsets.fromLTRB(side, 8, side, 84),
          duration: const Duration(seconds: 4),
        ),
      );
    // A sweep without a download folder asks for one instead of failing
    // silently behind the error text.
    if (code == 'DownloadRootMissing') {
      unawaited(_chooseDownloadRoot());
    }
  }

  Future<void> _chooseDownloadRoot() async {
    final picker = ref.read(sourcePickerProvider);
    if (picker == null) return;
    final String? directory;
    try {
      directory = await picker.chooseDirectory();
    } catch (_) {
      return;
    }
    if (directory == null || !mounted) return;
    final code = await ref
        .read(cloudSyncProvider.notifier)
        .setDownloadRoot(directory);
    if (!mounted) return;
    final strings = AppStrings.of(context);
    _notify(
      code == null
          ? strings.cloudDownloadRootApplied
          : strings.cloudError(code),
    );
  }

  Future<void> _setUploadScope() async {
    final cloud = ref.read(cloudSyncProvider);
    final albums = [
      for (final album in ref.read(localLibraryProvider).albums)
        if (!album.managed) album,
    ];
    final choice = await showDialog<_UploadScopeChoice>(
      context: context,
      builder: (context) => _UploadScopeDialog(
        albums: albums,
        mode: cloud.status.uploadScope,
        selected: cloud.status.uploadAlbums,
      ),
    );
    if (choice == null || !mounted) return;
    final code = await ref
        .read(cloudSyncProvider.notifier)
        .setUploadScope(choice.mode, choice.albums);
    if (!mounted) return;
    final strings = AppStrings.of(context);
    _notify(
      code == null ? strings.cloudUploadScopeApplied : strings.cloudError(code),
    );
  }

  Future<void> _showAccounts() async {
    final cloud = ref.read(cloudSyncProvider);
    final action = await showDialog<Object>(
      context: context,
      builder: (context) => _AccountsDialog(accounts: cloud.status.accounts),
    );
    if (action == null || !mounted) return;
    if (action is _AddAccount) {
      setState(() => _addingAccount = true);
      return;
    }
    if (action is _RemoveAccount) {
      final strings = AppStrings.of(context);
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => GlassAlertDialog(
          title: Text(strings.cloudRemoveAccountTitle),
          content: Text(
            strings.cloudRemoveAccountBody(action.account.username),
          ),
          actions: [
            TextButton(
              key: const ValueKey('cloud-remove-cancel'),
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(strings.cancel),
            ),
            FilledButton(
              key: const ValueKey('cloud-remove-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(strings.cloudRemoveAccount),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
      final code = await ref
          .read(cloudSyncProvider.notifier)
          .removeAccount(action.account.accountId);
      if (!mounted) return;
      _notify(
        code == null ? strings.cloudAccountRemoved : strings.cloudError(code),
      );
      return;
    }
    if (action is _SwitchAccount) {
      final code = await ref
          .read(cloudSyncProvider.notifier)
          .switchAccount(action.accountId);
      if (!mounted) return;
      if (code != null) _notify(AppStrings.of(context).cloudError(code));
    }
  }

  void _notify(String message) {
    if (!mounted) return;
    final width = MediaQuery.sizeOf(context).width;
    final side = width < 392 ? 16.0 : (width - 360) / 2;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          persist: false,
          margin: EdgeInsets.fromLTRB(side, 8, side, 84),
          duration: const Duration(seconds: 3),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final cloud = ref.watch(cloudSyncProvider);
    if (!cloud.available) {
      return Text(strings.cloudUnavailable);
    }
    final busy = cloud.busy;
    final code = cloud.errorCode;
    final lastSync = cloud.status.lastSyncMs;
    final localizations = MaterialLocalizations.of(context);
    final lastSyncLabel = lastSync == null
        ? strings.cloudNeverSynced
        : '${localizations.formatMediumDate(DateTime.fromMillisecondsSinceEpoch(lastSync))} '
              '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(lastSync)))}';
    Widget section(String title, List<Widget> children) => Padding(
      padding: const EdgeInsets.only(bottom: 20),
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
    final accounts = cloud.status.accounts;
    final showSignIn = _addingAccount || _signInExpanded;
    final showAccount = accounts.isNotEmpty || cloud.loggedIn;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          strings.cloudSyncBody,
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        if (cloud.loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          section(strings.cloudSync, [
            if (showAccount)
              _accountTile(cloud, busy, strings, showLogin: !showSignIn)
            else
              _signedOutTile(busy, strings, showLogin: !showSignIn),
            if (showAccount)
              ListTile(
                key: const ValueKey('cloud-download-root'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: const Icon(Icons.folder_outlined),
                title: Text(strings.cloudDownloadRoot),
                subtitle: Text(
                  cloud.status.downloadRoot ?? strings.cloudDownloadRootMissing,
                  style: cloud.status.downloadRoot == null
                      ? TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        )
                      : null,
                ),
                trailing: TextButton(
                  key: const ValueKey('cloud-choose-download-root'),
                  onPressed: busy
                      ? null
                      : () => unawaited(_chooseDownloadRoot()),
                  child: Text(strings.cloudChooseFolder),
                ),
              ),
            SwitchListTile(
              key: const ValueKey('cloud-auto-sync'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(strings.cloudAutoSync),
              subtitle: Text(
                cloud.loggedIn
                    ? strings.cloudAutoSyncHint
                    : strings.cloudAutoSyncNeedsSignIn,
              ),
              value: cloud.autoSync,
              onChanged: busy || !cloud.loggedIn
                  ? null
                  : (value) => unawaited(
                      ref.read(cloudSyncProvider.notifier).setAutoSync(value),
                    ),
            ),
            if (cloud.loggedIn && !_addingAccount) ...[
              const SizedBox(height: 6),
              _statusCard(cloud, lastSyncLabel, strings),
              const SizedBox(height: 8),
              _counts(cloud, strings),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    key: const ValueKey('cloud-sync-now'),
                    onPressed: busy ? null : () => unawaited(_syncNow()),
                    icon: busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.sync),
                    label: Text(strings.cloudSyncNow),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('cloud-logout'),
                    onPressed: busy ? null : () => unawaited(_logout()),
                    icon: const Icon(Icons.logout),
                    label: Text(strings.cloudSignOut),
                  ),
                ],
              ),
            ] else if (accounts.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  strings.cloudAccountSingleHint,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ]),
          if (cloud.loggedIn && !_addingAccount)
            section(strings.cloudUploadScope, [
              ListTile(
                key: const ValueKey('cloud-upload-scope'),
                contentPadding: EdgeInsets.zero,
                title: Text(_scopeSummary(cloud.status, strings)),
                subtitle: Text(strings.cloudUploadScopeHint),
                trailing: TextButton(
                  key: const ValueKey('cloud-choose-albums'),
                  onPressed: busy ? null : () => unawaited(_setUploadScope()),
                  child: Text(strings.cloudChooseAlbums),
                ),
              ),
            ]),
          if (showSignIn)
            section(
              _addingAccount
                  ? strings.cloudLoginOtherAccount
                  : strings.cloudSignIn,
              _signInFields(busy, strings),
            ),
          if (code != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: SelectableText(
                strings.cloudError(code),
                key: const ValueKey('cloud-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ],
    );
  }

  Widget _signedOutTile(
    bool busy,
    AppStrings strings, {
    required bool showLogin,
  }) {
    return ListTile(
      key: const ValueKey('cloud-signed-out'),
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.cloud_off_outlined),
      title: Text(strings.cloudNotSignedIn),
      subtitle: Text(strings.cloudSignInToSync),
      trailing: showLogin
          ? TextButton(
              key: const ValueKey('cloud-login-toggle'),
              onPressed: busy ? null : _expandSignIn,
              child: Text(strings.cloudSignIn),
            )
          : null,
    );
  }

  Widget _accountTile(
    CloudSyncState cloud,
    bool busy,
    AppStrings strings, {
    required bool showLogin,
  }) {
    final active = cloud.status.activeAccount;
    final name =
        cloud.status.username ?? active?.username ?? strings.cloudSignIn;
    final endpoint = cloud.status.endpoint ?? active?.endpoint ?? '';
    final subtitle = endpoint.isEmpty
        ? (cloud.loggedIn
              ? strings.cloudAccountSignedIn
              : strings.cloudSignInToSync)
        : (cloud.loggedIn
              ? endpoint
              : '$endpoint · ${strings.cloudAccountNeedsLogin}');
    return ListTile(
      key: const ValueKey('cloud-account'),
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        cloud.loggedIn ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
      ),
      title: Text(name),
      subtitle: Text(subtitle),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showLogin && !cloud.loggedIn)
            TextButton(
              key: const ValueKey('cloud-login-toggle'),
              onPressed: busy ? null : _expandSignIn,
              child: Text(strings.cloudSignIn),
            ),
          TextButton(
            key: const ValueKey('cloud-switch-account'),
            onPressed: busy ? null : () => unawaited(_showAccounts()),
            child: Text(strings.cloudSwitchAccount),
          ),
        ],
      ),
    );
  }

  Widget _statusCard(
    CloudSyncState cloud,
    String lastSyncLabel,
    AppStrings strings,
  ) {
    final copy = _statusCopy(cloud, lastSyncLabel, strings);
    final progress = _progress(cloud.status);
    final color = cloud.status.errorCode != null
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(GlassTheme.panelRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_statusIcon(cloud.status), color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  copy.$1,
                  key: const ValueKey('cloud-status-headline'),
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(color: color, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            copy.$2,
            key: const ValueKey('cloud-status-detail'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (progress != null) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              key: const ValueKey('cloud-progress'),
              value: progress,
              minHeight: 6,
              borderRadius: BorderRadius.circular(6),
            ),
          ],
        ],
      ),
    );
  }

  Widget _counts(CloudSyncState cloud, AppStrings strings) => Row(
    children: [
      Expanded(
        child: _count(
          strings.cloudPendingUploads,
          '${cloud.status.pendingUploads}',
        ),
      ),
      Expanded(
        child: _count(
          strings.cloudPendingFavorites,
          '${cloud.status.pendingFavorites}',
        ),
      ),
      Expanded(
        child: _count(strings.cloudBoundCount, '${cloud.status.boundCount}'),
      ),
    ],
  );

  Widget _count(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(value, style: Theme.of(context).textTheme.titleMedium),
      Text(
        label,
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ],
  );

  (String, String) _statusCopy(
    CloudSyncState cloud,
    String lastSyncLabel,
    AppStrings strings,
  ) {
    final status = cloud.status;
    final activity = status.activity;
    final code = status.errorCode;
    if (status.syncing) {
      final skipped = activity.skipped > 0
          ? ' ${strings.cloudSyncSkipped(activity.skipped)}'
          : '';
      switch (activity.phase) {
        case 'preparing':
          return (strings.cloudSyncPreparing, strings.cloudSyncChecking);
        case 'receiving':
          return (
            strings.cloudSyncReceiving,
            activity.downloadTotal > 0
                ? '${strings.cloudSyncReceivingProgress(activity.downloaded, activity.downloadTotal)}$skipped'
                : '${strings.cloudSyncChecking}$skipped',
          );
        case 'uploading':
          final parts = <String>[];
          if (activity.uploadTotal > 0) {
            parts.add(
              strings.cloudSyncUploadingProgress(
                activity.uploaded,
                activity.uploadTotal,
              ),
            );
          }
          if (activity.favoriteTotal > 0) {
            parts.add(
              strings.cloudSyncFavoriteProgress(
                activity.favoritesUploaded,
                activity.favoriteTotal,
              ),
            );
          }
          return (
            strings.cloudSyncUploading,
            parts.isEmpty
                ? '${strings.cloudSyncChecking}$skipped'
                : '${parts.join(' · ')}$skipped',
          );
        case 'finalizing':
          return (strings.cloudSyncFinalizing, strings.cloudSyncChecking);
        default:
          return (strings.syncing, strings.cloudSyncChecking);
      }
    }
    if (code != null) {
      return (strings.cloudErrorHeadline(code), strings.cloudError(code));
    }
    if (status.failedUploads > 0) {
      return (
        strings.cloudSyncNeedsAttention,
        strings.cloudUploadFailedCount(status.failedUploads),
      );
    }
    final detail = status.lastSyncMs == null
        ? strings.cloudSyncReadyDetail(
            status.pendingUploads,
            status.pendingFavorites,
          )
        : strings.cloudSyncIdleDetail(
            lastSyncLabel,
            status.pendingUploads,
            status.pendingFavorites,
          );
    return (strings.cloudSyncReady, detail);
  }

  double? _progress(CloudStatus status) {
    if (!status.syncing) return null;
    final activity = status.activity;
    if (activity.phase == 'receiving' && activity.downloadTotal > 0) {
      return (activity.downloaded / activity.downloadTotal).clamp(0.0, 1.0);
    }
    if (activity.phase == 'uploading') {
      final total = activity.uploadTotal + activity.favoriteTotal;
      if (total > 0) {
        return ((activity.uploaded + activity.favoritesUploaded) / total).clamp(
          0.0,
          1.0,
        );
      }
    }
    return null;
  }

  IconData _statusIcon(CloudStatus status) {
    if (status.errorCode != null) return Icons.error_outline;
    if (status.syncing) return Icons.cloud_sync_outlined;
    return Icons.cloud_done_outlined;
  }

  String _scopeSummary(CloudStatus status, AppStrings strings) {
    if (status.uploadScope == 'all') return strings.cloudUploadScopeAll;
    if (status.uploadScope == 'selected' && status.uploadAlbums.isNotEmpty) {
      return strings.cloudUploadScopeSelected(status.uploadAlbums.length);
    }
    return strings.cloudUploadScopeNone;
  }

  List<Widget> _signInFields(bool busy, AppStrings strings) => [
    TextField(
      key: const ValueKey('cloud-endpoint'),
      controller: _endpoint,
      enabled: !busy,
      keyboardType: TextInputType.url,
      autocorrect: false,
      decoration: InputDecoration(
        labelText: strings.cloudEndpoint,
        hintText: strings.cloudEndpointHint,
      ),
    ),
    const SizedBox(height: 12),
    TextField(
      key: const ValueKey('cloud-username'),
      controller: _username,
      enabled: !busy,
      autocorrect: false,
      decoration: InputDecoration(labelText: strings.cloudUsername),
    ),
    const SizedBox(height: 12),
    TextField(
      key: const ValueKey('cloud-password'),
      controller: _password,
      enabled: !busy,
      obscureText: true,
      enableSuggestions: false,
      autocorrect: false,
      decoration: InputDecoration(
        labelText: strings.cloudPassword,
        helperText: strings.cloudPasswordHint,
      ),
      onSubmitted: (_) => unawaited(_login()),
    ),
    const SizedBox(height: 12),
    Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            key: const ValueKey('cloud-login'),
            onPressed: busy ? null : () => unawaited(_login()),
            icon: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.login),
            label: Text(strings.cloudSignIn),
          ),
          TextButton(
            key: const ValueKey('cloud-login-cancel'),
            onPressed: busy ? null : _collapseSignIn,
            child: Text(strings.cancel),
          ),
        ],
      ),
    ),
  ];
}

class _SwitchAccount {
  const _SwitchAccount(this.accountId);
  final String accountId;
}

class _AddAccount {
  const _AddAccount();
}

class _RemoveAccount {
  const _RemoveAccount(this.account);
  final CloudAccount account;
}

class _AccountsDialog extends StatelessWidget {
  const _AccountsDialog({required this.accounts});
  final List<CloudAccount> accounts;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return GlassDialog(
      constraints: const BoxConstraints(
        minWidth: 320,
        maxWidth: 560,
        maxHeight: 600,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 16, 8),
            child: Text(
              strings.cloudAccounts,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final account in accounts)
                  ListTile(
                    key: ValueKey('cloud-account-${account.accountId}'),
                    leading: Icon(
                      account.active
                          ? Icons.check_circle_outline
                          : Icons.account_circle_outlined,
                    ),
                    title: Text(account.username),
                    subtitle: Text(
                      '${account.endpoint} · ${account.signedIn ? strings.cloudAccountSignedIn : strings.cloudAccountNeedsLogin}',
                    ),
                    trailing: PopupMenuButton<String>(
                      key: ValueKey('cloud-account-menu-${account.accountId}'),
                      onSelected: (_) =>
                          Navigator.of(context).pop(_RemoveAccount(account)),
                      itemBuilder: (context) => [
                        PopupMenuItem(
                          value: 'remove',
                          child: Text(strings.cloudRemoveAccount),
                        ),
                      ],
                    ),
                    onTap: account.active
                        ? null
                        : () =>
                              Navigator.of(context)
                                  .pop(_SwitchAccount(account.accountId)),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: OverflowBar(
              alignment: MainAxisAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  key: const ValueKey('cloud-login-other'),
                  onPressed: () =>
                      Navigator.of(context).pop(const _AddAccount()),
                  child: Text(strings.cloudLoginOtherAccount),
                ),
                TextButton(
                  key: const ValueKey('cloud-accounts-close'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(strings.close),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _UploadScopeChoice {
  const _UploadScopeChoice(this.mode, this.albums);
  final String mode;
  final List<String> albums;
}

class _UploadScopeDialog extends StatefulWidget {
  const _UploadScopeDialog({
    required this.albums,
    required this.mode,
    required this.selected,
  });
  final List<LocalAlbum> albums;
  final String mode;
  final List<String> selected;

  @override
  State<_UploadScopeDialog> createState() => _UploadScopeDialogState();
}

class _UploadScopeDialogState extends State<_UploadScopeDialog> {
  late String _mode = widget.mode == 'selected' || widget.mode == 'all'
      ? widget.mode
      : 'none';
  late final Set<String> _selected = widget.selected.toSet();

  void _save() {
    final albums = _mode == 'selected'
        ? [
            for (final album in widget.albums)
              if (_selected.contains(album.path)) album.path,
          ]
        : const <String>[];
    Navigator.of(context).pop(
      _UploadScopeChoice(
        _mode == 'selected' && albums.isEmpty ? 'none' : _mode,
        albums,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return GlassDialog(
      constraints: const BoxConstraints(
        minWidth: 360,
        maxWidth: 620,
        maxHeight: 680,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 8),
            child: Text(
              strings.cloudUploadScopeTitle,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              strings.cloudUploadScopeHint,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                RadioGroup<String>(
                  groupValue: _mode,
                  onChanged: (value) {
                    if (value != null) setState(() => _mode = value);
                  },
                  child: Column(
                    children: [
                      RadioListTile<String>(
                        key: const ValueKey('cloud-scope-none'),
                        value: 'none',
                        title: Text(strings.cloudUploadScopeReceiveOnly),
                      ),
                      RadioListTile<String>(
                        key: const ValueKey('cloud-scope-selected'),
                        value: 'selected',
                        title: Text(strings.cloudUploadScopeSelectedOption),
                      ),
                      RadioListTile<String>(
                        key: const ValueKey('cloud-scope-all'),
                        value: 'all',
                        title: Text(strings.cloudUploadScopeAllOption),
                      ),
                    ],
                  ),
                ),
                if (_mode == 'selected') ...[
                  const Divider(),
                  if (widget.albums.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(strings.cloudUploadScopeEmpty),
                    )
                  else
                    for (final album in widget.albums)
                      CheckboxListTile(
                        key: ValueKey('cloud-scope-album-${album.path}'),
                        value: _selected.contains(album.path),
                        title: Text(album.name),
                        subtitle: Text('${album.path} · ${album.count}'),
                        onChanged: (checked) => setState(() {
                          if (checked == true) {
                            _selected.add(album.path);
                          } else {
                            _selected.remove(album.path);
                          }
                        }),
                      ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: OverflowBar(
              alignment: MainAxisAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  key: const ValueKey('cloud-upload-scope-cancel'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(strings.cancel),
                ),
                FilledButton(
                  key: const ValueKey('cloud-upload-scope-save'),
                  onPressed: _save,
                  child: Text(strings.save),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
