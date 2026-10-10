import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'push_avatar.dart';

/// Send a message typed into a notification's inline reply box.
///
/// A plaintext room is sent straight to the homeserver rather than through the
/// Rust client: the notification path runs in a background isolate that must
/// not start a second Matrix client against the same store, and an unencrypted
/// message needs no device keys. Encrypted rooms never expose the reply action
/// for the same reason.
///
/// Returns true when the homeserver accepted the message.
Future<bool> sendNotificationReply({
  required String userId,
  required String roomId,
  required String body,
  PushMediaSession? session,
  /// Injectable for tests; production uses the default client.
  http.Client? client,
}) async {
  final text = body.trim();
  if (text.isEmpty) return false;
  if (!roomId.startsWith('!')) return false;
  final media = session ?? await loadPushMediaSession(userId);
  if (media == null) return false;

  final base = media.homeserver.trim().replaceFirst(RegExp(r'/+$'), '');
  final txnId = newReplyTransactionId();
  final uri = Uri.parse(
    '$base/_matrix/client/v3/rooms/${Uri.encodeComponent(roomId)}'
    '/send/m.room.message/${Uri.encodeComponent(txnId)}',
  );
  final request = http.Request('PUT', uri)
    ..headers.addAll({
      'Authorization': 'Bearer ${media.accessToken}',
      'Content-Type': 'application/json',
    })
    ..body = jsonEncode({'msgtype': 'm.text', 'body': text});
  try {
    final response = await (client ?? http.Client())
        .send(request)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      debugPrint('Notification reply rejected: HTTP ${response.statusCode}');
      return false;
    }
    return true;
  } catch (error) {
    debugPrint('Notification reply failed: ${error.runtimeType}');
    return false;
  }
}

/// Unique idempotency key, so a retried request cannot double-send.
String newReplyTransactionId() {
  final random = Random.secure();
  final suffix = base64Url.encode(
    List.generate(12, (_) => random.nextInt(256)),
  );
  return 'matter-push-${DateTime.now().microsecondsSinceEpoch}-$suffix';
}
