import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/downloads/download_notification.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('moe.aks.matter/downloads');
  late List<MethodCall> calls;
  setUp(() {
    calls = [];
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'start' ? 10001 : null;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('starts foreground transfer and publishes verified installer path', () async {
    final notification = await DownloadNotification.start('matter.apk');
    notification.progress(5, 10);
    notification.progress(6, 10);
    await notification.complete(installPath: '/cache/updates/matter.apk');
    expect(calls.map((call) => call.method), ['start', 'progress', 'finish']);
    expect(calls.first.arguments, {'filename': 'matter.apk'});
    expect(calls[1].arguments, {'id': 10001, 'received': 5, 'total': 10});
    expect(calls.last.arguments, {
      'id': 10001,
      'status': 'complete',
      'installPath': '/cache/updates/matter.apk',
    });
  });

  test('distinguishes failure from user cancellation', () async {
    final failed = await DownloadNotification.start('report.pdf');
    await failed.fail('network unavailable');
    final cancelled = await DownloadNotification.start('matter.apk');
    await cancelled.cancel();
    expect(calls[1].arguments, {
      'id': 10001,
      'status': 'failed',
      'error': 'network unavailable',
    });
    expect(calls.last.arguments, {'id': 10001, 'status': 'cancelled'});
  });

  test('does not call the Android service on other platforms', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final notification = await DownloadNotification.start('report.pdf');
    notification.progress(1, 2);
    await notification.complete();
    expect(calls, isEmpty);
  });
}
