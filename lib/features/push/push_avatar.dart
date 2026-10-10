import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Keep enough avatars on disk for the rooms and people that notify.
const _maxCachedAvatars = 128;

/// Directory holding downloaded notification avatars.
const _avatarDirName = 'matter_push_avatars';

const _accessTokenKeyPrefix = 'matrix_access_token_';

String _accessTokenKey(String userId) =>
    '$_accessTokenKeyPrefix${base64Url.encode(utf8.encode(userId))}';

String pushAvatarIndexKey(String userId) =>
    'push_avatar_files_${base64Url.encode(utf8.encode(userId))}';

/// Host and token needed to reach the homeserver outside the Rust client.
///
/// Used for the inline reply, which posts over plain HTTP so it never has to
/// start a second Matrix client in the background isolate.
class PushMediaSession {
  const PushMediaSession({required this.homeserver, required this.accessToken});

  final String homeserver;
  final String accessToken;
}

Future<PushMediaSession?> loadPushMediaSession(String userId) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final raw = prefs.getString('multi_sessions');
  if (raw == null) return null;
  String? homeserver;
  try {
    final sessions = jsonDecode(raw);
    if (sessions is List) {
      for (final session in sessions) {
        if (session is Map<String, dynamic> &&
            session['user_id'] == userId &&
            session['homeserver_url'] is String) {
          homeserver = session['homeserver_url'] as String;
          break;
        }
      }
    }
  } on FormatException {
    return null;
  }
  if (homeserver == null) return null;
  final token = await const FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
  ).read(key: _accessTokenKey(userId));
  if (token == null || token.isEmpty) return null;
  return PushMediaSession(homeserver: homeserver, accessToken: token);
}

/// Absolute path of a notification avatar file, or null when not cached.
///
/// Only stored paths are returned, so the background isolate needs neither
/// `path_provider` nor the network to resolve an avatar: the foreground wrote
/// the file and the absolute path, and `BitmapFactory` decodes the file
/// natively on the Android side.
Future<String?> pushAvatarPath(String userId, String mxc) async {
  if (mxc.isEmpty) return null;
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final raw = prefs.getString(pushAvatarIndexKey(userId));
  if (raw == null) return null;
  Map<String, dynamic> index;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return null;
    index = decoded;
  } on FormatException {
    return null;
  }
  final path = index[mxc];
  if (path is! String || path.isEmpty) return null;
  // A stale path (cache cleared, app data moved) must not be handed to
  // Android: decoding a missing file yields no icon and logs an error.
  return await File(path).exists() ? path : null;
}

/// Downloads and caches notification avatars on disk.
///
/// Runs in the foreground, where the Rust client already holds a valid
/// session, so avatar fetching never depends on reading credentials from the
/// FCM background isolate.
class PushAvatarCache {
  PushAvatarCache({required this.download});

  /// Fetch raw bytes for an `mxc://` URI, e.g. `rust.downloadMediaBytes`.
  final Future<Uint8List?> Function(String mxc) download;

  Future<String?> _directory() async {
    final base = await getApplicationSupportDirectory();
    final directory = Directory('${base.path}/$_avatarDirName');
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory.path;
  }

  Future<Map<String, dynamic>> _loadIndex(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(pushAvatarIndexKey(userId));
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : {};
    } on FormatException {
      return {};
    }
  }

  /// Ensures an avatar is on disk, deduplicating concurrent requests.
  ///
  /// The prefetch is driven by sync updates, so two runs can overlap and ask
  /// for the same avatar before either has written it. Without this, both
  /// would download and write the same file.
  final Map<String, Future<String?>> _inFlight = {};

  /// Ensure [mxc] is on disk and return its absolute path.
  ///
  /// Returns null when the avatar cannot be fetched; a missing avatar must
  /// never fail a notification, so every error is swallowed.
  Future<String?> ensure(String userId, String mxc) {
    if (!mxc.startsWith('mxc://')) return Future.value();
    final key = '$userId\n$mxc';
    final pending = _inFlight[key];
    if (pending != null) return pending;
    final request = _ensure(userId, mxc);
    _inFlight[key] = request;
    // The callback uses a block body on purpose: `whenComplete` awaits the
    // value it returns, and `remove` would hand back the very future being
    // awaited, deadlocking the request.
    return request.whenComplete(() {
      _inFlight.remove(key);
    });
  }

  Future<String?> _ensure(String userId, String mxc) async {
    if (!mxc.startsWith('mxc://')) return null;
    final cached = await pushAvatarPath(userId, mxc);
    if (cached != null) return cached;

    final bytes = await download(mxc);
    if (bytes == null || bytes.isEmpty) return null;
    try {
      final directory = await _directory();
      if (directory == null) return null;
      // Name the file per account as well as per avatar. Content-addressing on
      // the mxc alone would make two accounts share one file, so clearing one
      // account's cache would delete a file the other still references.
      final name = sha256.convert(utf8.encode('$userId\n$mxc')).toString();
      final file = File('$directory/$name.img');
      await file.writeAsBytes(bytes, flush: true);

      final index = await _loadIndex(userId);
      index[mxc] = file.path;
      // Bound growth by dropping entries until the file count fits, deleting
      // the files too so the cache cannot grow without limit on disk.
      while (index.length > _maxCachedAvatars) {
        final oldest = index.keys.first;
        final path = index.remove(oldest);
        if (path is String) {
          try {
            final stale = File(path);
            if (await stale.exists()) await stale.delete();
          } catch (error) {
            debugPrint('Push avatar eviction failed: ${error.runtimeType}');
          }
        }
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(pushAvatarIndexKey(userId), jsonEncode(index));
      return file.path;
    } catch (error) {
      debugPrint('Push avatar cache write failed: ${error.runtimeType}');
      return null;
    }
  }

  /// Drop an account's cached avatars, files included.
  Future<void> clearAccount(String userId) async {
    final index = await _loadIndex(userId);
    for (final path in index.values) {
      if (path is! String) continue;
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (error) {
        debugPrint('Push avatar cleanup failed: ${error.runtimeType}');
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(pushAvatarIndexKey(userId));
  }
}
