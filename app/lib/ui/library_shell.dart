import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/local_library_gateway.dart';
import 'glass_surface.dart';
import 'local_library_pane.dart';
import 'presentation_preferences.dart';
import 'runtime_controller.dart';
import 'strings.dart';

class LibraryShell extends ConsumerStatefulWidget {
  const LibraryShell({super.key});

  @override
  ConsumerState<LibraryShell> createState() => _LibraryShellState();
}

class _LibraryShellState extends ConsumerState<LibraryShell> {
  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final runtime = ref.watch(runtimeProvider);
    final localMode = ref.read(coreGatewayProvider) is LocalLibraryGateway;
    final preferences = ref.watch(presentationProvider);
    final scheme = Theme.of(context).colorScheme;
    final labels = [strings.library, strings.connection, strings.settings];
    const icons = [
      Icons.photo_library_outlined,
      Icons.hub_outlined,
      Icons.tune,
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 600;
        final expanded = constraints.maxWidth >= 1024;
        final content = Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          labels[_selected],
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          localMode ? strings.localStage : strings.stage,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  Tooltip(
                    message: strings.settings,
                    child: IconButton(
                      key: const ValueKey('appearance-shortcut'),
                      onPressed: () => setState(() => _selected = 2),
                      icon: const Icon(Icons.contrast),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: SizedBox(
                    height: 64,
                    child: GlassSurface(
                      live: true,
                      enabled: preferences.glass,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            _ConnectionIcon(runtime: runtime),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _connectionLabel(strings, runtime.phase),
                                key: const ValueKey('connection-status'),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: _selected == 0 && localMode
                  ? const LocalLibraryPane()
                  : SingleChildScrollView(
                      key: const ValueKey('page-scroll'),
                      padding: const EdgeInsets.all(24),
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 760),
                          child: switch (_selected) {
                            0 => _LibraryEmpty(
                              onConnection: () => setState(() => _selected = 1),
                            ),
                            1 => _ConnectionPanel(runtime: runtime),
                            _ => const _AppearancePanel(),
                          },
                        ),
                      ),
                    ),
            ),
          ],
        );
        return Scaffold(
          bottomNavigationBar: compact
              ? NavigationBar(
                  key: const ValueKey('compact-navigation'),
                  selectedIndex: _selected,
                  onDestinationSelected: (index) =>
                      setState(() => _selected = index),
                  destinations: [
                    for (var i = 0; i < labels.length; i++)
                      NavigationDestination(
                        icon: Icon(icons[i]),
                        label: labels[i],
                      ),
                  ],
                )
              : null,
          body: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  scheme.primary.withValues(alpha: .07),
                  Colors.transparent,
                  scheme.tertiary.withValues(alpha: .04),
                ],
              ),
            ),
            child: SafeArea(
              child: Row(
                children: [
                  if (!compact)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 16, 0, 16),
                      child: GlassSurface(
                        enabled: preferences.glass,
                        child: NavigationRail(
                          key: ValueKey(
                            expanded ? 'wide-navigation' : 'medium-navigation',
                          ),
                          extended: expanded,
                          backgroundColor: Colors.transparent,
                          minExtendedWidth: 224,
                          selectedIndex: _selected,
                          onDestinationSelected: (index) =>
                              setState(() => _selected = index),
                          labelType: expanded
                              ? NavigationRailLabelType.none
                              : NavigationRailLabelType.all,
                          leading: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 16,
                              horizontal: 8,
                            ),
                            child: expanded
                                ? Text(
                                    strings.appTitle,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge,
                                  )
                                : Tooltip(
                                    message: strings.appTitle,
                                    child: const Icon(Icons.camera_outlined),
                                  ),
                          ),
                          destinations: [
                            for (var i = 0; i < labels.length; i++)
                              NavigationRailDestination(
                                icon: Icon(icons[i]),
                                label: Text(labels[i]),
                              ),
                          ],
                        ),
                      ),
                    ),
                  Expanded(child: content),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

String _connectionLabel(AppStrings strings, ConnectionPhase phase) =>
    switch (phase) {
      ConnectionPhase.connecting => strings.connecting,
      ConnectionPhase.ready => strings.ready,
      ConnectionPhase.failed => strings.failed,
      ConnectionPhase.stopped => strings.stopped,
    };

class _ConnectionIcon extends StatelessWidget {
  const _ConnectionIcon({required this.runtime});
  final RuntimeViewState runtime;
  @override
  Widget build(BuildContext context) {
    if (runtime.phase == ConnectionPhase.connecting) {
      return const SizedBox.square(
        dimension: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return Icon(
      switch (runtime.phase) {
        ConnectionPhase.ready => Icons.check_circle_outline,
        ConnectionPhase.failed => Icons.error_outline,
        _ => Icons.power_settings_new,
      },
      color: runtime.phase == ConnectionPhase.failed
          ? Theme.of(context).colorScheme.error
          : Theme.of(context).colorScheme.primary,
    );
  }
}

class _LibraryEmpty extends StatelessWidget {
  const _LibraryEmpty({required this.onConnection});
  final VoidCallback onConnection;
  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.photo_library_outlined,
            size: 52,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 24),
          Text(
            strings.emptyTitle,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          Text(strings.emptyBody, style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            key: const ValueKey('open-connection'),
            onPressed: onConnection,
            icon: const Icon(Icons.hub_outlined),
            label: Text(strings.openConnection),
          ),
          const SizedBox(height: 16),
          Text(
            strings.foundationHint,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _ConnectionPanel extends ConsumerWidget {
  const _ConnectionPanel({required this.runtime});
  final RuntimeViewState runtime;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = AppStrings.of(context);
    final snapshot = runtime.snapshot;
    final problem = runtime.problem;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(strings.connectionBody),
        const SizedBox(height: 24),
        if (problem != null) ...[
          Semantics(
            liveRegion: true,
            child: _ReadingPanel(
              child: Text(switch (problem) {
                RuntimeProblem.initialization => strings.initializeError,
                RuntimeProblem.eventStream => strings.streamError,
                RuntimeProblem.roundTrip => strings.probeError,
                RuntimeProblem.shutdown => strings.shutdownError,
              }, key: const ValueKey('core-error')),
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (runtime.phase == ConnectionPhase.failed)
          FilledButton.icon(
            key: const ValueKey('retry-connection'),
            onPressed: () => ref.read(runtimeProvider.notifier).initialize(),
            icon: const Icon(Icons.refresh),
            label: Text(strings.retry),
          ),
        if (snapshot != null) ...[
          _ReadingPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Detail(label: strings.profile, value: snapshot.profileId),
                _Detail(
                  label: strings.protocol,
                  value: '${snapshot.bridgeProtocolVersion}',
                ),
                _Detail(label: strings.session, value: snapshot.sessionId),
                _Detail(label: strings.digest, value: snapshot.profileDigest),
                _Detail(
                  label: strings.runtimeStatus,
                  value: runtime.runtimeStatus ?? snapshot.status,
                ),
                _Detail(
                  label: strings.event,
                  value: runtime.sequence?.toString() ?? strings.waitingEvent,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            key: const ValueKey('round-trip'),
            onPressed:
                runtime.phase == ConnectionPhase.ready && !runtime.probing
                ? () => ref.read(runtimeProvider.notifier).probe()
                : null,
            icon: const Icon(Icons.sync_alt),
            label: Text(runtime.probing ? strings.probing : strings.probe),
          ),
          if (runtime.reply != null) ...[
            const SizedBox(height: 20),
            _ReadingPanel(
              child: _Detail(label: strings.reply, value: runtime.reply!),
            ),
          ],
        ],
      ],
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        SelectableText(value),
      ],
    ),
  );
}

class _ReadingPanel extends StatelessWidget {
  const _ReadingPanel({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    child: child,
  );
}

class _AppearancePanel extends ConsumerWidget {
  const _AppearancePanel();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = AppStrings.of(context);
    final preferences = ref.watch(presentationProvider);
    final controller = ref.read(presentationProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(strings.appearanceBody),
        const SizedBox(height: 24),
        _ReadingPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                strings.theme,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (mode, label) in [
                    (ThemeMode.system, strings.system),
                    (ThemeMode.light, strings.light),
                    (ThemeMode.dark, strings.dark),
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected: preferences.themeMode == mode,
                      onSelected: (_) => controller.setTheme(mode),
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                    ),
                ],
              ),
              const SizedBox(height: 24),
              Text(
                strings.language,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (locale, label) in [
                    (const Locale('zh', 'CN'), '简体中文'),
                    (const Locale('en'), 'English'),
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected:
                          Localizations.localeOf(context).languageCode ==
                          locale.languageCode,
                      onSelected: (_) => controller.setLocale(locale),
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                    ),
                ],
              ),
              const SizedBox(height: 24),
              Text(
                strings.glass,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: Text(strings.glassOn),
                    selected: preferences.glass,
                    onSelected: (_) => controller.setGlass(true),
                  ),
                  ChoiceChip(
                    label: Text(strings.glassOff),
                    selected: !preferences.glass,
                    onSelected: (_) => controller.setGlass(false),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(strings.glassHint),
            ],
          ),
        ),
      ],
    );
  }
}
