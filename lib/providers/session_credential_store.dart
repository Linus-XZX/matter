import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kCompatibilityMode = 'session_credential_compatibility_mode_v1';
const _kCompatibilityModePending =
    'session_credential_compatibility_mode_pending_v1';
const _credentialFileName = 'session_credentials_compatibility_v1.json';

class SessionCredentials {
  final String accessToken;
  final String? refreshToken;

  const SessionCredentials({
    required this.accessToken,
    required this.refreshToken,
  });
}

class SessionCredentialStoreException implements Exception {
  final String message;

  const SessionCredentialStoreException(this.message);

  @override
  String toString() => 'SessionCredentialStoreException: $message';
}

bool _credentialOperationActive = false;
final _credentialOperationWaiters = <Completer<void>>[];

Future<T> _serializeCredentialOperation<T>(
  Future<T> Function() operation,
) async {
  if (_credentialOperationActive) {
    final turn = Completer<void>();
    _credentialOperationWaiters.add(turn);
    await turn.future;
  } else {
    _credentialOperationActive = true;
  }

  try {
    return await operation();
  } finally {
    if (_credentialOperationWaiters.isEmpty) {
      _credentialOperationActive = false;
    } else {
      _credentialOperationWaiters.removeAt(0).complete();
    }
  }
}

bool isKeystoreFailure(Object error) {
  final text = '$error'.toLowerCase();
  return text.contains('failed to unwrap key') ||
      text.contains('oaep_decoding_error') ||
      text.contains('keystoreexception') ||
      text.contains('badpaddingexception') ||
      text.contains('invalidkeyexception') ||
      text.contains('migration failed after algorithm change') ||
      text.contains('key type incompatible with cipher');
}

bool get _isCompatibilityStoreAvailable =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

Future<bool> _isSessionCredentialCompatibilityModeEnabled() async {
  if (!_isCompatibilityStoreAvailable) return false;
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(_kCompatibilityModePending) ?? false) {
    if (!(prefs.getBool(_kCompatibilityMode) ?? false)) {
      await _clearAllCompatibilitySessionCredentials();
    }
    await prefs.remove(_kCompatibilityModePending);
  }
  return prefs.getBool(_kCompatibilityMode) ?? false;
}

Future<bool> isSessionCredentialCompatibilityModeEnabled() =>
    _serializeCredentialOperation(_isSessionCredentialCompatibilityModeEnabled);

Future<void> _enableSessionCredentialCompatibilityMode() async {
  if (!_isCompatibilityStoreAvailable) {
    throw StateError('凭据兼容模式仅适用于 Android');
  }
  final prefs = await SharedPreferences.getInstance();
  final saved = await prefs.setBool(_kCompatibilityMode, true);
  if (!saved) {
    throw StateError('无法保存兼容模式设置');
  }
}

Future<void> enableSessionCredentialCompatibilityMode() =>
    _serializeCredentialOperation(_enableSessionCredentialCompatibilityMode);

Future<void> disableSessionCredentialCompatibilityMode() =>
    _serializeCredentialOperation(() async {
      if (!_isCompatibilityStoreAvailable) return;
      await _clearAllCompatibilitySessionCredentials();
      final prefs = await SharedPreferences.getInstance();
      final removed = await prefs.remove(_kCompatibilityMode);
      if (!removed && prefs.containsKey(_kCompatibilityMode)) {
        throw StateError('无法关闭兼容模式');
      }
    });

Future<bool> storeSessionCredentials({
  required String userId,
  required String accessToken,
  String? refreshToken,
  required Future<void> Function() writeSecureCredentials,
}) => _serializeCredentialOperation(() async {
  if (await _isSessionCredentialCompatibilityModeEnabled()) {
    await _writeCompatibilitySessionCredentials(
      userId: userId,
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    return true;
  }
  await writeSecureCredentials();
  return false;
});

Future<({SessionCredentials? credentials, bool compatibilityMode})>
readSessionCredentials({
  required String userId,
  required Future<SessionCredentials?> Function() readSecureCredentials,
}) => _serializeCredentialOperation(() async {
  final compatibilityMode =
      await _isSessionCredentialCompatibilityModeEnabled();
  return (
    credentials: compatibilityMode
        ? await _readCompatibilitySessionCredentials(userId)
        : await readSecureCredentials(),
    compatibilityMode: compatibilityMode,
  );
});

Future<void> removeSessionCredentials({
  required String userId,
  required Future<void> Function() deleteSecureCredentials,
}) => _serializeCredentialOperation(() async {
  if (_isCompatibilityStoreAvailable) {
    await _deleteCompatibilitySessionCredentials(userId);
  }
  await deleteSecureCredentials();
});

Future<Object?> recoverSessionCredentialStore({
  required Map<String, SessionCredentials> recoveredCredentials,
  required Future<Map<String, SessionCredentials>> Function()
  loadLatestCredentials,
  required bool Function(Set<String> recoveredUserIds) shouldResetSecureValues,
  required Future<void> Function() resetSecureValues,
}) => _serializeCredentialOperation(() async {
  if (!_isCompatibilityStoreAvailable) {
    throw StateError('凭据兼容模式故障恢复仅适用于 Android');
  }
  final credentials = {
    ...recoveredCredentials,
    ...await loadLatestCredentials(),
  };
  final prefs = await SharedPreferences.getInstance();
  final pendingSaved = await prefs.setBool(_kCompatibilityModePending, true);
  if (!pendingSaved) {
    throw StateError('无法保存兼容模式恢复状态');
  }
  try {
    await _writeCredentialMap({
      for (final entry in credentials.entries)
        entry.key: {
          'access_token': entry.value.accessToken,
          if (entry.value.refreshToken case final refreshToken?
              when refreshToken.isNotEmpty)
            'refresh_token': refreshToken,
        },
    });

    final saved = await prefs.setBool(_kCompatibilityMode, true);
    if (!saved) {
      throw StateError('无法保存兼容模式设置');
    }
  } catch (_) {
    if (!(prefs.getBool(_kCompatibilityMode) ?? false)) {
      await _clearAllCompatibilitySessionCredentials();
    }
    await prefs.remove(_kCompatibilityModePending);
    rethrow;
  }
  await prefs.remove(_kCompatibilityModePending);

  if (!shouldResetSecureValues(credentials.keys.toSet())) {
    return null;
  }
  try {
    await resetSecureValues();
    return null;
  } catch (error) {
    // Compatibility credentials are already durable and the mode flag is on,
    // so a failed cleanup of the now-unused secure store is non-fatal.
    return error;
  }
});

Future<SessionCredentials?> readCompatibilitySessionCredentials(
  String userId,
) => _serializeCredentialOperation(() async {
  if (!_isCompatibilityStoreAvailable) return null;
  return _readCompatibilitySessionCredentials(userId);
});

Future<SessionCredentials?> _readCompatibilitySessionCredentials(
  String userId,
) async {
  final credentials = await _readCredentialMap();
  final value = credentials[userId];
  if (value is! Map<String, dynamic>) return null;
  final accessToken = value['access_token'];
  if (accessToken is! String || accessToken.isEmpty) return null;
  final refreshToken = value['refresh_token'];
  return SessionCredentials(
    accessToken: accessToken,
    refreshToken: refreshToken is String && refreshToken.isNotEmpty
        ? refreshToken
        : null,
  );
}

Future<void> writeCompatibilitySessionCredentials({
  required String userId,
  required String accessToken,
  String? refreshToken,
}) => _serializeCredentialOperation(() {
  if (!_isCompatibilityStoreAvailable) {
    throw StateError('凭据兼容模式仅适用于 Android');
  }
  return _writeCompatibilitySessionCredentials(
    userId: userId,
    accessToken: accessToken,
    refreshToken: refreshToken,
  );
});

Future<void> _writeCompatibilitySessionCredentials({
  required String userId,
  required String accessToken,
  String? refreshToken,
}) async {
  Map<String, dynamic> credentials;
  try {
    credentials = await _readCredentialMap();
  } on FormatException {
    await _clearAllCompatibilitySessionCredentials();
    credentials = {};
  }
  credentials[userId] = {
    'access_token': accessToken,
    if (refreshToken != null && refreshToken.isNotEmpty)
      'refresh_token': refreshToken,
  };
  await _writeCredentialMap(credentials);
}

Future<void> deleteCompatibilitySessionCredentials(String userId) =>
    _serializeCredentialOperation(
      () => _isCompatibilityStoreAvailable
          ? _deleteCompatibilitySessionCredentials(userId)
          : Future<void>.value(),
    );

Future<void> _deleteCompatibilitySessionCredentials(String userId) async {
  final file = await _credentialFile();
  if (!file.existsSync()) return;

  late final Map<String, dynamic> credentials;
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('兼容凭据文件格式无效');
    }
    credentials = Map<String, dynamic>.from(decoded);
  } on FormatException {
    await _clearAllCompatibilitySessionCredentials();
    return;
  }
  if (credentials.remove(userId) == null) return;
  if (credentials.isEmpty) {
    await _clearAllCompatibilitySessionCredentials();
    return;
  }
  await _writeCredentialMap(credentials);
}

Future<void> clearAllCompatibilitySessionCredentials() =>
    _serializeCredentialOperation(
      () => _isCompatibilityStoreAvailable
          ? _clearAllCompatibilitySessionCredentials()
          : Future<void>.value(),
    );

Future<void> _clearAllCompatibilitySessionCredentials() async {
  final file = await _credentialFile();
  if (file.existsSync()) {
    file.deleteSync();
  }
  final temporary = File('${file.path}.tmp');
  if (temporary.existsSync()) {
    temporary.deleteSync();
  }
}

Future<Map<String, dynamic>> _readCredentialMap() async {
  final file = await _credentialFile();
  if (!await file.exists()) return {};
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('兼容凭据文件格式无效');
  }
  return Map<String, dynamic>.from(decoded);
}

Future<void> _writeCredentialMap(Map<String, dynamic> credentials) async {
  final file = await _credentialFile();
  final temporary = File('${file.path}.tmp');
  await temporary.writeAsString(jsonEncode(credentials), flush: true);
  await temporary.rename(file.path);
}

Future<File> _credentialFile() async {
  final directory = await getApplicationSupportDirectory();
  return File('${directory.path}/$_credentialFileName');
}
