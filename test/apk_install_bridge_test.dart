import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/app_update/apk_installer_io.dart';
import 'package:matter/features/app_update/update_exception.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('moe.aks.matter/app_update');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  for (final entry in {
    'installApk': installAndroidApk,
    'showInFiles': showAndroidApkInFiles,
  }.entries) {
    test('${entry.key} forwards the downloaded path to Android', () async {
      MethodCall? received;
      messenger.setMockMethodCallHandler(channel, (call) async {
        received = call;
        return null;
      });
      await entry.value('/cache/updates/matter.apk');
      expect(received?.method, entry.key);
      expect(received?.arguments, {'path': '/cache/updates/matter.apk'});
    });

    test('${entry.key} reports native errors to the update dialog', () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'unavailable', message: '系统无法处理安装包');
      });
      await expectLater(
        entry.value('/cache/updates/matter.apk'),
        throwsA(
          isA<AppUpdateException>().having(
            (error) => error.message,
            'message',
            '系统无法处理安装包',
          ),
        ),
      );
    });

    test('${entry.key} reports an unavailable platform', () async {
      await expectLater(
        entry.value('/cache/updates/matter.apk'),
        throwsA(isA<AppUpdateException>()),
      );
    });
  }
}
