import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/file_download_saver.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'support/temp_path_provider.dart';

const _fileSelectorChannel = MethodChannel('plugins.flutter.io/file_selector');

class _DownloadPaths extends TempPathProvider {
  _DownloadPaths(super.root);

  @override
  Future<String?> getDownloadsPath() async => '${root.path}/Downloads';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late int dialogs;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('matter-save-test');
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _DownloadPaths(directory);
    addTearDown(() => PathProviderPlatform.instance = previous);
    dialogs = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_fileSelectorChannel, (call) async {
          dialogs++;
          return null;
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_fileSelectorChannel, null);
    await directory.delete(recursive: true);
  });

  test('saves straight to Downloads without a location picker', () async {
    expect(
      await saveDownloadedFile(
        filename: 'report.pdf',
        bytes: Uint8List.fromList([1, 2, 3]),
      ),
      isTrue,
    );
    expect(await File('${directory.path}/Downloads/report.pdf').readAsBytes(), [
      1,
      2,
      3,
    ]);
    expect(dialogs, 0);
  });

  test('keeps existing files and names new copies with a suffix', () async {
    final downloads = Directory('${directory.path}/Downloads');
    await downloads.create();
    await File('${downloads.path}/report.pdf').writeAsBytes([9]);
    await saveDownloadedFile(
      filename: 'report.pdf',
      bytes: Uint8List.fromList([1]),
    );
    await saveDownloadedFile(
      filename: 'report.pdf',
      bytes: Uint8List.fromList([2]),
    );
    expect(await File('${downloads.path}/report.pdf').readAsBytes(), [9]);
    expect(await File('${downloads.path}/report (1).pdf').readAsBytes(), [1]);
    expect(await File('${downloads.path}/report (2).pdf').readAsBytes(), [2]);
    expect(dialogs, 0);
  });

  test('simultaneous downloads never overwrite one another', () async {
    await Future.wait([
      for (var i = 0; i < 3; i++)
        saveDownloadedFile(filename: 'README', bytes: Uint8List.fromList([i])),
    ]);
    final files = await Directory('${directory.path}/Downloads')
        .list()
        .toList();
    expect(files.length, 3);
    final contents = await Future.wait(
      files.map((file) => File(file.path).readAsBytes()),
    );
    expect(contents.map((bytes) => bytes.single).toSet(), {0, 1, 2});
  });
}
