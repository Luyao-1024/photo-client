import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/local_library_gateway.dart';
import '../ui/glass_dialog.dart';
import '../ui/glass_theme.dart';
import '../ui/strings.dart';

/// Platform file access stays here; the picker uses the app's own window chrome.
class InAppSourcePicker implements LocalSourcePicker {
  InAppSourcePicker(this.navigator);
  final GlobalKey<NavigatorState> navigator;
  String? _lastDirectory;
  Future<List<String>> _choose(bool directory) async {
    final context = navigator.currentContext;
    if (context == null) return [];
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    final paths = await showDialog<List<String>>(
      context: context,
      builder: (_) => _LocalFileBrowser(
        directory: directory,
        initialPath: _lastDirectory ?? home,
      ),
    );
    if (paths != null && paths.isNotEmpty) {
      _lastDirectory = directory ? paths.first : File(paths.first).parent.path;
    }
    return paths ?? [];
  }

  @override
  Future<List<String>> chooseFiles() => _choose(false);
  @override
  Future<String?> chooseDirectory() async {
    final paths = await _choose(true);
    return paths.firstOrNull;
  }
}

class _LocalFileBrowser extends StatefulWidget {
  const _LocalFileBrowser({required this.directory, required this.initialPath});
  final bool directory;
  final String initialPath;
  @override
  State<_LocalFileBrowser> createState() => _LocalFileBrowserState();
}

class _LocalFileBrowserState extends State<_LocalFileBrowser> {
  late String _path = widget.initialPath;
  late final TextEditingController _location = TextEditingController(
    text: _path,
  );
  final _locationFocus = FocusNode();
  List<FileSystemEntity> _entries = [];
  final Set<String> _selected = {};
  String? _selectedDirectory;
  bool _loading = true, _failed = false, _hidden = false;
  int _generation = 0;
  static const extensions = {
    'jpg',
    'jpeg',
    'png',
    'webp',
    'gif',
    'heic',
    'heif',
    'mp4',
    'm4v',
    'mov',
    'webm',
    'mkv',
    'avi',
  };
  String _name(String path) =>
      path
          .split(Platform.pathSeparator)
          .where((part) => part.isNotEmpty)
          .lastOrNull ??
      path;
  bool _supported(String path) =>
      extensions.contains(path.split('.').last.toLowerCase());
  @override
  void initState() {
    super.initState();
    unawaited(_navigate(_path));
  }

  @override
  void dispose() {
    _generation++;
    _location.dispose();
    _locationFocus.dispose();
    super.dispose();
  }

  Future<void> _navigate(String value) async {
    if (value.trim().isEmpty) return;
    final token = ++_generation;
    var path = value.trim();
    final home = Platform.environment['HOME'];
    if (home != null && (path == '~' || path.startsWith('~/'))) {
      path = home + path.substring(1);
    }
    if (!Directory(path).isAbsolute) {
      path = '$_path${Platform.pathSeparator}$path';
    }
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final entityType = await FileSystemEntity.type(path, followLinks: false);
      if (!widget.directory &&
          entityType == FileSystemEntityType.file &&
          _supported(path)) {
        if (mounted && token == _generation) {
          Navigator.of(context).pop([File(path).absolute.path]);
        }
        return;
      }
      final directory = Directory(path);
      final resolved = await directory.resolveSymbolicLinks();
      final entries = <FileSystemEntity>[];
      await for (final entity in Directory(resolved).list(followLinks: false)) {
        final name = _name(entity.path);
        if (!_hidden && name.startsWith('.')) continue;
        if (entity is Directory ||
            (!widget.directory && entity is File && _supported(entity.path))) {
          entries.add(entity);
        }
      }
      entries.sort((a, b) {
        final folder = (a is Directory ? 0 : 1).compareTo(
          b is Directory ? 0 : 1,
        );
        return folder != 0
            ? folder
            : _name(a.path)
                  .toLowerCase()
                  .compareTo(_name(b.path).toLowerCase());
      });
      if (!mounted || token != _generation) return;
      setState(() {
        _path = resolved;
        _location.text = resolved;
        _entries = entries;
        _selected.clear();
        _selectedDirectory = null;
        _loading = false;
      });
    } catch (_) {
      if (mounted && token == _generation) {
        setState(() {
          _failed = true;
          _loading = false;
        });
      }
    }
  }

  void _accept() {
    if (_loading || _failed) return;
    if (widget.directory) {
      Navigator.of(context).pop([_selectedDirectory ?? _path]);
    } else if (_selected.isNotEmpty) {
      Navigator.of(context).pop(_selected.toList());
    }
  }

  void _selectAll() {
    if (_locationFocus.hasFocus) return;
    setState(
      () =>
          _selected.addAll(_entries.whereType<File>().map((file) => file.path)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final scheme = Theme.of(context).colorScheme;
    return GlassDialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820, maxHeight: 680),
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyL, control: true): () =>
                _locationFocus.requestFocus(),
            if (!widget.directory && !_locationFocus.hasFocus)
              const SingleActivator(LogicalKeyboardKey.keyA, control: true):
                  _selectAll,
          },
          child: Focus(
            autofocus: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          strings.pick(
                            widget.directory ? '选择文件夹' : '选择照片或视频',
                            widget.directory
                                ? 'Choose folder'
                                : 'Choose photos or videos',
                          ),
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        tooltip: strings.close,
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: strings.pick('上一级', 'Parent folder'),
                        onPressed:
                            _loading || Directory(_path).parent.path == _path
                            ? null
                            : () => _navigate(Directory(_path).parent.path),
                        icon: const Icon(Icons.arrow_upward),
                      ),
                      IconButton(
                        tooltip: strings.pick('主目录', 'Home'),
                        onPressed: () => _navigate(
                          Platform.environment['HOME'] ??
                              Directory.current.path,
                        ),
                        icon: const Icon(Icons.home_outlined),
                      ),
                      Expanded(
                        child: TextField(
                          key: const ValueKey('file-browser-location'),
                          controller: _location,
                          focusNode: _locationFocus,
                          onSubmitted: _navigate,
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: strings.pick(
                              '输入路径，按回车打开',
                              'Enter a path and press Enter',
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: strings.refresh,
                        onPressed: () => _navigate(_location.text),
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const Divider(height: 1),
                Flexible(
                  child: SizedBox(
                    height: 440,
                    child: _loading
                        ? const Center(child: CircularProgressIndicator())
                        : _failed
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  strings.pick(
                                    '无法打开此文件夹，请检查路径或访问权限。',
                                    'This folder could not open. Check the path or permissions.',
                                  ),
                                ),
                                TextButton(
                                  onPressed: () => _navigate(_location.text),
                                  child: Text(strings.retry),
                                ),
                              ],
                            ),
                          )
                        : _entries.isEmpty
                        ? Center(
                            child: Text(
                              strings.pick(
                                widget.directory
                                    ? '此文件夹没有子文件夹，可选择当前文件夹。'
                                    : '此文件夹没有支持的照片或视频。',
                                widget.directory
                                    ? 'No subfolders. You can choose the current folder.'
                                    : 'No supported photos or videos in this folder.',
                              ),
                            ),
                          )
                        : ListView.builder(
                            itemCount: _entries.length,
                            itemBuilder: (context, index) {
                              final entry = _entries[index];
                              final directory = entry is Directory;
                              final selected = directory
                                  ? _selectedDirectory == entry.path
                                  : _selected.contains(entry.path);
                              return Material(
                                color: selected
                                    ? GlassTheme.of(context).selection
                                    : Colors.transparent,
                                child: InkWell(
                                  onTap: () => setState(() {
                                    if (directory) {
                                      _selectedDirectory = entry.path;
                                    } else if (!_selected.remove(entry.path)) {
                                      _selected.add(entry.path);
                                    }
                                  }),
                                  onDoubleTap: () => directory
                                      ? _navigate(entry.path)
                                      : _accept(),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 4,
                                    ),
                                    child: Row(
                                      children: [
                                        if (!directory)
                                          Checkbox(
                                            value: selected,
                                            onChanged: (_) => setState(() {
                                              if (!_selected.remove(
                                                entry.path,
                                              )) {
                                                _selected.add(entry.path);
                                              }
                                            }),
                                          ),
                                        Icon(
                                          directory
                                              ? Icons.folder_outlined
                                              : Icons.image_outlined,
                                          color: selected
                                              ? scheme.primary
                                              : null,
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Text(
                                            _name(entry.path),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: selected
                                                  ? scheme.primary
                                                  : null,
                                              fontWeight: selected
                                                  ? FontWeight.w600
                                                  : null,
                                            ),
                                          ),
                                        ),
                                        if (directory)
                                          IconButton(
                                            tooltip: strings.pick(
                                              '打开文件夹',
                                              'Open folder',
                                            ),
                                            onPressed: () =>
                                                _navigate(entry.path),
                                            icon: const Icon(
                                              Icons.chevron_right,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Checkbox(
                        value: _hidden,
                        onChanged: (value) {
                          setState(() => _hidden = value ?? false);
                          unawaited(_navigate(_path));
                        },
                      ),
                      Flexible(
                        child: Text(
                          strings.pick('显示隐藏文件', 'Show hidden files'),
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text(strings.cancel),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        key: const ValueKey('file-browser-accept'),
                        onPressed:
                            _loading ||
                                _failed ||
                                (!widget.directory && _selected.isEmpty)
                            ? null
                            : _accept,
                        child: Text(
                          widget.directory
                              ? strings.pick('选择文件夹', 'Choose folder')
                              : strings.pick(
                                  '选择 ${_selected.length} 项',
                                  'Choose ${_selected.length} items',
                                ),
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
