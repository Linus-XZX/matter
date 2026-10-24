import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const _fileSaveChannel = MethodChannel('moe.aks.matter/file_saver');

Future<bool> saveDownloadedFile({
  required String filename,
  required Uint8List bytes,
}) async {
  if (!Platform.isAndroid && !Platform.isIOS) {
    final directory = await getDownloadsDirectory();
    if (directory == null) throw const FileSystemException('无法获取下载目录');
    await directory.create(recursive: true);
    final dot = filename.lastIndexOf('.');
    final stem = dot > 0 ? filename.substring(0, dot) : filename;
    final extension = dot > 0 ? filename.substring(dot) : '';
    for (var copy = 0; ; copy++) {
      final name = copy == 0 ? filename : '$stem ($copy)$extension';
      final file = File('${directory.path}/$name');
      try {
        await file.create(exclusive: true);
      } on FileSystemException {
        if (await FileSystemEntity.type(file.path) !=
            FileSystemEntityType.notFound) {
          continue;
        }
        rethrow;
      }
      try {
        await file.writeAsBytes(bytes, flush: true);
      } catch (_) {
        await file.delete();
        rethrow;
      }
      return true;
    }
  }

  final cacheDirectory = await getTemporaryDirectory();
  final downloadDirectory = Directory(
    '${cacheDirectory.path}/matter_downloads',
  );
  await downloadDirectory.create(recursive: true);
  final operationDirectory = await downloadDirectory.createTemp('download-');
  final file = File('${operationDirectory.path}/$filename');
  await file.writeAsBytes(bytes, flush: true);
  try {
    return await _fileSaveChannel.invokeMethod<bool>('saveFile', {
          'path': file.path,
        }) ??
        false;
  } finally {
    if (await operationDirectory.exists()) {
      await operationDirectory.delete(recursive: true);
    }
  }
}
