import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps Android downloads alive while the app is in the background.
class DownloadNotification {
  static const _channel = MethodChannel('moe.aks.matter/downloads');
  final int? _id;
  DateTime? _lastProgress;

  DownloadNotification._(this._id);

  static Future<DownloadNotification> start(String filename) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return DownloadNotification._(null);
    }
    final id = await _channel.invokeMethod<int>('start', {'filename': filename});
    return DownloadNotification._(id);
  }

  void progress(int received, int total) {
    if (_id == null) return;
    final now = DateTime.now();
    if (_lastProgress != null &&
        now.difference(_lastProgress!) < const Duration(seconds: 1)) {
      return;
    }
    _lastProgress = now;
    unawaited(_send('progress', {'received': received, 'total': total}));
  }

  Future<void> complete({String? installPath}) => _send('finish', {
    'status': 'complete',
    'installPath': ?installPath,
  });

  Future<void> fail(Object error) =>
      _send('finish', {'status': 'failed', 'error': error.toString()});

  Future<void> cancel() => _send('finish', {'status': 'cancelled'});

  Future<void> _send(String method, Map<String, Object> arguments) async {
    if (_id == null) return;
    try {
      await _channel.invokeMethod<void>(method, {'id': _id, ...arguments});
    } on PlatformException catch (error) {
      debugPrint('Failed to update download notification: $error');
    }
  }
}
