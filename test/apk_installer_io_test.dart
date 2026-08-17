import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/app_update/apk_installer_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  final previousHttpOverrides = HttpOverrides.current;
  late Directory temporaryDirectory;
  late HttpServer server;
  var requests = 0;
  List<int>? servedBytes;

  setUp(() async {
    HttpOverrides.global = null;
    requests = 0;
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'matter_update_test_',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getTemporaryDirectory') {
            return temporaryDirectory.path;
          }
          return null;
        });
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      requests++;
      final bytes = servedBytes;
      if (bytes == null) {
        request.response.statusCode = HttpStatus.internalServerError;
      } else {
        request.response
          ..statusCode = HttpStatus.ok
          ..contentLength = bytes.length
          ..add(bytes);
      }
      request.response.close();
    });
  });

  tearDown(() async {
    HttpOverrides.global = previousHttpOverrides;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    await server.close(force: true);
    await temporaryDirectory.delete(recursive: true);
    servedBytes = null;
  });

  test('reuses a verified cached APK without downloading it again', () async {
    final bytes = <int>[1, 2, 3, 4, 5];
    final updateDirectory = Directory('${temporaryDirectory.path}/updates');
    await updateDirectory.create();
    final cachedApk = File('${updateDirectory.path}/matter.apk');
    await cachedApk.writeAsBytes(bytes);

    final path = await downloadAndroidApk(
      uri: Uri.parse(
        'http://${server.address.address}:${server.port}/matter.apk',
      ),
      fileName: 'matter.apk',
      expectedSize: bytes.length,
      digest: 'sha256:${sha256.convert(bytes)}',
      onProgress: (_, _) {},
    );

    expect(path, cachedApk.path);
    expect(requests, 0);
  });

  test('redownloads when the cached APK size does not match', () async {
    final updateDirectory = Directory('${temporaryDirectory.path}/updates');
    await updateDirectory.create();
    final cachedApk = File('${updateDirectory.path}/matter.apk');
    await cachedApk.writeAsBytes(<int>[1, 2, 3]);

    final bytes = <int>[1, 2, 3, 4, 5];
    servedBytes = bytes;

    final path = await downloadAndroidApk(
      uri: Uri.parse(
        'http://${server.address.address}:${server.port}/matter.apk',
      ),
      fileName: 'matter.apk',
      expectedSize: bytes.length,
      digest: 'sha256:${sha256.convert(bytes)}',
      onProgress: (_, _) {},
    );

    expect(requests, 1);
    expect(path, cachedApk.path);
    expect(await cachedApk.readAsBytes(), bytes);
  });

  test('redownloads when the cached APK digest does not match', () async {
    final updateDirectory = Directory('${temporaryDirectory.path}/updates');
    await updateDirectory.create();
    final cachedApk = File('${updateDirectory.path}/matter.apk');
    await cachedApk.writeAsBytes(<int>[9, 9, 9, 9, 9]);

    final bytes = <int>[1, 2, 3, 4, 5];
    servedBytes = bytes;

    final path = await downloadAndroidApk(
      uri: Uri.parse(
        'http://${server.address.address}:${server.port}/matter.apk',
      ),
      fileName: 'matter.apk',
      expectedSize: bytes.length,
      digest: 'sha256:${sha256.convert(bytes)}',
      onProgress: (_, _) {},
    );

    expect(requests, 1);
    expect(path, cachedApk.path);
    expect(await cachedApk.readAsBytes(), bytes);
  });
}
