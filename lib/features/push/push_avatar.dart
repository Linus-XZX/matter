import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Avatars are small; keep enough of them cached to avoid re-downloading on
/// every message of a conversation.
const _maxCachedAvatars = 64;

/// Reject anything an avatar cannot plausibly need. A 96x96 thumbnail is a
/// few KB; the cap only guards against a misbehaving endpoint, and oversized
/// bytes would be marshalled into the notification payload.
const _maxAvatarBytes = 128 * 1024;

const _accessTokenKeyPrefix = 'matrix_access_token_';

String _accessTokenKey(String userId) =>
    '$_accessTokenKeyPrefix${base64Url.encode(utf8.encode(userId))}';

String pushAvatarCacheKey(String userId) =>
    'push_avatars_${base64Url.encode(utf8.encode(userId))}';

/// Host and token needed to fetch authenticated media for an account.
///
/// The background isolate cannot start the Rust client, but it can read the
/// session metadata the foreground already persists.
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

/// Thumbnail URL for an `mxc://` avatar.
///
/// Mirrors the Rust `mxc_to_thumbnail_http` helper: `mxc://server/id` maps to
/// the authenticated media endpoint on the account's homeserver.
String? mxcThumbnailUrl(
  String mxc, {
  required String homeserver,
  int width = 96,
  int height = 96,
}) {
  final uri = Uri.tryParse(mxc);
  if (uri == null || uri.scheme != 'mxc') return null;
  final server = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  final mediaId = uri.path.replaceFirst('/', '');
  if (server.isEmpty || mediaId.isEmpty) return null;
  final base = homeserver.trim().replaceFirst(RegExp(r'/+$'), '');
  if (base.isEmpty) return null;
  return '$base/_matrix/client/v1/media/thumbnail/$server/$mediaId'
      '?width=$width&height=$height&method=scale';
}

/// Fetches and caches avatars for notifications.
///
/// Only unencrypted media is fetched. Matrix avatars are plain media, so no
/// event content is decrypted here.
class PushAvatarStore {
  /// SharedPreferences caps a stored string at a few megabytes, so the byte
  /// payloads are base64 encoded as values in one JSON object per account.
  Future<Map<String, dynamic>> _loadRaw(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(pushAvatarCacheKey(userId));
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : {};
    } on FormatException {
      return {};
    }
  }

  /// Return cached avatar bytes for [mxc], or null when not cached yet.
  Future<Uint8List?> cached(String userId, String mxc) async {
    final entry = (await _loadRaw(userId))[mxc];
    if (entry is! String) return null;
    try {
      return base64Decode(entry);
    } on FormatException {
      return null;
    }
  }

  Future<void> save(String userId, String mxc, Uint8List bytes) async {
    final raw = await _loadRaw(userId);
    raw[mxc] = base64Encode(bytes);
    // Bound growth: drop arbitrary oldest-by-insertion entries. Avatars are
    // interchangeable cache entries, so eviction order is not observable.
    while (raw.length > _maxCachedAvatars) {
      raw.remove(raw.keys.first);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(pushAvatarCacheKey(userId), jsonEncode(raw));
  }

  Future<void> clearAccount(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(pushAvatarCacheKey(userId));
  }
}

/// Fetch [mxc] for [userId], preferring the cache.
///
/// Returns null on any failure: a missing avatar must never block or fail a
/// notification.
Future<Uint8List?> loadAvatarBytes({
  required PushAvatarStore store,
  required String userId,
  required String mxc,
  PushMediaSession? session,
}) async {
  final cached = await store.cached(userId, mxc);
  if (cached != null) return cached;
  final media = session ?? await loadPushMediaSession(userId);
  if (media == null) return null;
  final url = mxcThumbnailUrl(mxc, homeserver: media.homeserver);
  if (url == null) return null;
  try {
    final response = await http
        .get(Uri.parse(url), headers: {'Authorization': 'Bearer ${media.accessToken}'})
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200 || response.bodyBytes.isEmpty) return null;
    if (response.bodyBytes.length > _maxAvatarBytes) return null;
    final bytes = response.bodyBytes;
    await store.save(userId, mxc, bytes);
    return bytes;
  } catch (error) {
    debugPrint('Push avatar fetch failed: ${error.runtimeType}');
    return null;
  }
}
