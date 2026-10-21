import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'local_library_controller.dart';
import 'strings.dart';

Future<String?> createLocalAlbum(BuildContext context, WidgetRef ref) async {
  final picker = ref.read(sourcePickerProvider);
  if (picker == null) return null;
  final parent = await picker.chooseDirectory();
  if (parent == null || !context.mounted) return null;
  final strings = AppStrings.of(context);
  final name = TextEditingController();
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(strings.pick('新建相册', 'New album')),
      content: TextField(
        key: const ValueKey('album-name-field'),
        controller: name,
        autofocus: true,
        decoration: InputDecoration(
          labelText: strings.pick('相册名称', 'Album name'),
        ),
        onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: const ValueKey('album-create-confirm'),
          onPressed: () => Navigator.of(context).pop(name.text.trim()),
          child: Text(strings.pick('创建', 'Create')),
        ),
      ],
    ),
  );
  name.dispose();
  if (result == null || result.isEmpty) return null;
  try {
    final controller = ref.read(localLibraryProvider.notifier);
    final folder = await controller.localCommand({
      'op': 'createAlbum',
      'parent': parent,
      'name': result,
    }) as String?;
    await controller.refresh(force: true);
    return folder;
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(strings.actionFailed)));
    }
    return null;
  }
}
