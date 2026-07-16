import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class MarkdownSourceStore {
  static const _prefix = 'markdown_source_v3';
  static const _legacyPrefix = 'markdown_source_v2:';

  const MarkdownSourceStore();

  String _key(String userId, String roomId, String eventId) =>
      '$_prefix:${Uri.encodeComponent(userId)}:${Uri.encodeComponent(roomId)}:${Uri.encodeComponent(eventId)}';

  Future<void> save({
    required String userId,
    required String roomId,
    required String eventId,
    required String source,
    required String body,
    required String? formattedBody,
    required bool persist,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _key(userId, roomId, eventId);
    if (!persist) {
      await prefs.remove(key);
      return;
    }
    await prefs.setString(
      key,
      jsonEncode({
        'source': source,
        'body': body,
        'formattedBody': formattedBody,
      }),
    );
  }

  Future<String?> load({
    required String userId,
    required String roomId,
    required String eventId,
    required String body,
    required String? formattedBody,
    required bool allowPersistence,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _key(userId, roomId, eventId);
    if (!allowPersistence) {
      await prefs.remove(key);
      return null;
    }
    final raw = prefs.getString(key);
    if (raw == null) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic> ||
          value['body'] != body ||
          value['formattedBody'] != formattedBody) {
        await prefs.remove(key);
        return null;
      }
      return value['source'] as String?;
    } catch (_) {
      await prefs.remove(key);
      return null;
    }
  }

  Future<void> delete({
    required String userId,
    required String roomId,
    required String eventId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(userId, roomId, eventId));
  }

  Future<void> clearForUser(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final prefix = '$_prefix:${Uri.encodeComponent(userId)}:';
    for (final key in prefs.getKeys().where((key) => key.startsWith(prefix))) {
      await prefs.remove(key);
    }
  }

  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys().where((key) => key.startsWith(_prefix))) {
      await prefs.remove(key);
    }
  }

  static Future<void> clearLegacyEntries() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys().where(
      (key) => key.startsWith(_legacyPrefix),
    )) {
      await prefs.remove(key);
    }
  }
}
