import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'cloud_sync_controller.dart';
import 'glass_theme.dart';
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

  @override
  void initState() {
    super.initState();
    final status = ref.read(cloudSyncProvider).status;
    _endpoint.text = status.endpoint ?? '';
    _username.text = status.username ?? '';
    _subscription = ref.listenManual<CloudSyncState>(cloudSyncProvider, (
      previous,
      next,
    ) {
      if (next.loggedIn || !mounted) return;
      if (_endpoint.text.isEmpty && next.status.endpoint != null) {
        _endpoint.text = next.status.endpoint!;
      }
      if (_username.text.isEmpty && next.status.username != null) {
        _username.text = next.status.username!;
      }
    });
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
    await ref
        .read(cloudSyncProvider.notifier)
        .login(endpoint: endpoint, username: username, password: password);
    _password.clear();
  }

  Future<void> _syncNow() async {
    final report = await ref.read(cloudSyncProvider.notifier).syncNow();
    if (report == null || !mounted || report.failed > 0) return;
    final strings = AppStrings.of(context);
    // A full-width toast sits over the sidebar's bottom rows and swallows the
    // clicks on the settings entry for the seconds it lives. Keep it in the
    // middle of the window and off the side navigation.
    final width = MediaQuery.sizeOf(context).width;
    final side = width < 392 ? 16.0 : (width - 360) / 2;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            strings.cloudSyncedCounts(
              report.downloaded,
              report.uploaded,
              report.favoritesApplied + report.favoritesUploaded,
            ),
          ),
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
        else if (cloud.loggedIn)
          section(strings.cloudSync, [
            ListTile(
              key: const ValueKey('cloud-account'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.cloud_done_outlined),
              title: Text(cloud.status.username ?? ''),
              subtitle: Text(cloud.status.endpoint ?? ''),
            ),
            _row(
              strings.cloudLastSync,
              cloud.status.syncing ? strings.syncing : lastSyncLabel,
            ),
            _row(strings.cloudPendingUploads, '${cloud.status.pendingUploads}'),
            _row(
              strings.cloudPendingFavorites,
              '${cloud.status.pendingFavorites}',
            ),
            _row(strings.cloudBoundCount, '${cloud.status.boundCount}'),
            const SizedBox(height: 12),
            SwitchListTile(
              key: const ValueKey('cloud-auto-sync'),
              contentPadding: EdgeInsets.zero,
              title: Text(strings.cloudAutoSync),
              subtitle: Text(strings.cloudAutoSyncHint),
              value: cloud.autoSync,
              onChanged: busy
                  ? null
                  : (value) => unawaited(
                      ref.read(cloudSyncProvider.notifier).setAutoSync(value),
                    ),
            ),
            const SizedBox(height: 12),
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
                  onPressed: busy
                      ? null
                      : () => unawaited(
                          ref.read(cloudSyncProvider.notifier).logout(),
                        ),
                  icon: const Icon(Icons.logout),
                  label: Text(strings.cloudSignOut),
                ),
              ],
            ),
          ])
        else
          section(strings.cloudSignIn, [
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
              child: FilledButton.icon(
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
            ),
            if (lastSync != null) ...[
              const SizedBox(height: 8),
              Text(
                '${strings.cloudLastSync}: $lastSyncLabel',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ]),
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
    );
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        Text(value, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}
