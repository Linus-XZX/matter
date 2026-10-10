import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'push_avatar.dart';
import 'push_settings.dart';

String pushRoomMuteKey(String userId, String roomId) =>
    'push_room_mute_${base64Url.encode(utf8.encode('$userId\n$roomId'))}';

/// Perform an explicit notification action without starting another SDK client.
/// Only acknowledged writes allow the caller to dismiss the notification.
Future<bool> performNotificationRoomAction({
  required PushTarget target,
  required bool mute,
  PushMediaSession? session,
  http.Client? client,
}) async {
  http.Client? ownedClient;
  try {
    final media = session ?? await loadPushMediaSession(target.userId);
    if (media == null) return false;
    final transport = client ?? (ownedClient = http.Client());
    final base = media.homeserver.trim().replaceFirst(RegExp(r'/+$'), '');
    final room = Uri.encodeComponent(target.roomId);
    final headers = {
      'Authorization': 'Bearer ${media.accessToken}',
      'Content-Type': 'application/json',
    };
    Future<bool> write(
      String method,
      String path,
      Map<String, dynamic> body,
    ) async {
      final request =
          http.Request(method, Uri.parse('$base/_matrix/client/v3/$path'))
            ..headers.addAll(headers)
            ..body = jsonEncode(body);
      final response = await transport
          .send(request)
          .timeout(const Duration(seconds: 5));
      return response.statusCode >= 200 && response.statusCode < 300;
    }

    if (mute) {
      // Match the SDK's override rule: it precedes mention/content rules.
      final path = 'pushrules/global/override/$room';
      if (!await write('PUT', path, {
        'actions': <String>[],
        'conditions': [
          {'kind': 'event_match', 'key': 'room_id', 'pattern': target.roomId},
        ],
      })) {
        return false;
      }
      // Replacing an existing disabled rule does not re-enable it.
      if (!await write('PUT', '$path/enabled', {'enabled': true})) return false;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        pushRoomMuteKey(target.userId, target.roomId),
        DateTime.now().microsecondsSinceEpoch,
      );
    } else {
      if (!await write(
        'POST',
        'rooms/$room/receipt/m.read/${Uri.encodeComponent(target.eventId)}',
        {},
      )) {
        return false;
      }
      // Explicit reads clear marks set on any client, even before a sync echo.
      if (!await write(
        'PUT',
        'user/${Uri.encodeComponent(target.userId)}/rooms/$room/account_data/m.marked_unread',
        {'unread': false},
      )) {
        return false;
      }
    }
    return true;
  } catch (error) {
    debugPrint('Notification room action failed: ${error.runtimeType}');
    return false;
  } finally {
    ownedClient?.close();
  }
}
