import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_client/services/cloud_sync_gateway.dart';
import 'package:photo_client/ui/strings.dart';

void main() {
  test(
    'scope changes retain their stable error and explain why sync stopped',
    () {
      expect(
        cloudErrorCode(Exception('CloudScopeChanged')),
        'CloudScopeChanged',
      );
      expect(
        AppStrings(const Locale('en')).cloudError('CloudScopeChanged'),
        contains('identity changed'),
      );
      expect(
        AppStrings(const Locale('zh')).cloudError('CloudScopeChanged'),
        contains('已停止同步'),
      );
    },
  );
}
