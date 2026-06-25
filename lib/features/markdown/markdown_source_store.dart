import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class MarkdownSourceStore {
  static const _prefix = 'markdown_source_v2';

  const MarkdownSourceStore();

  String _key(String roomId, String eventId) =>
      '$_prefix:${Uri.encodeComponent(roomId)}:${Uri.encodeComponent(eventId)}';

  Future<void> save({
    required String roomId,
    required String eventId,
    required String source,
    required String body,
    required String? formattedBody,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key(roomId, eventId),
      jsonEncode({
        'source': source,
        'body': body,
        'formattedBody': formattedBody,
      }),
    );
  }

  Future<String?> load({
    required String roomId,
    required String eventId,
    required String body,
    required String? formattedBody,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _key(roomId, eventId);
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

  Future<void> delete({required String roomId, required String eventId}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(roomId, eventId));
  }
}
