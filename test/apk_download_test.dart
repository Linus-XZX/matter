import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matter/features/app_update/apk_installer_io.dart';
import 'package:matter/features/app_update/update_exception.dart';

import 'support/temp_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('moe.aks.matter/downloads');
  final uri = Uri.parse('https://github.com/slopwerks/matter/matter.apk');
  late Directory directory;
  late List<MethodCall> notifications;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('matter-apk-');
    installTempPathProvider(directory);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    notifications = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          notifications.add(call);
          return call.method == 'start' ? 10001 : null;
        });
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  Future<String> download({String? digest, int size = 3}) => downloadAndroidApk(
    uri: uri,
    fileName: 'matter.apk',
    expectedSize: size,
    digest: digest,
    onProgress: (_, _) {},
  );

  test('only publishes an installer path after size and hash validation', () async {
    final bytes = [1, 2, 3];
    final path = await http.runWithClient(
      () => download(digest: 'sha256:${sha256.convert(bytes)}'),
      () => MockClient((_) async => http.Response.bytes(bytes, 200)),
    );
    expect(await File(path).readAsBytes(), bytes);
    expect(notifications.last.arguments, {
      'id': 10001,
      'status': 'complete',
      'installPath': path,
    });
  });

  for (final invalidHash in [false, true]) {
    test('failed ${invalidHash ? 'hash' : 'size'} validation leaves no installer', () async {
      await http.runWithClient(
        () => expectLater(
          download(
            digest: invalidHash ? 'sha256:${'0' * 64}' : null,
            size: invalidHash ? 3 : 4,
          ),
          throwsA(isA<AppUpdateException>()),
        ),
        () => MockClient((_) async => http.Response.bytes([1, 2, 3], 200)),
      );
      expect(notifications.last.arguments['status'], 'failed');
      expect(notifications.last.arguments.containsKey('installPath'), isFalse);
      expect(await directory.list(recursive: true).where((entry) => entry is File).toList(), isEmpty);
    });
  }

  test('prevents concurrent writers to the same installer file', () async {
    final response = Completer<http.Response>();
    final entered = Completer<void>();
    await http.runWithClient(() async {
      final pending = download();
      await entered.future;
      await expectLater(download(), throwsA(isA<AppUpdateException>()));
      response.complete(http.Response.bytes([1, 2, 3], 200));
      await pending;
    }, () => MockClient((_) {
      entered.complete();
      return response.future;
    }));
    expect(notifications.where((call) => call.method == 'start').length, 1);
  });
}
