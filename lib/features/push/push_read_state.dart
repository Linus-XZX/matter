import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'push_avatar.dart';

/// Check the homeserver's notification read flags, including receipts sent
/// from other clients. Unknown or unavailable results never suppress a message.
Future<Set<String>> fetchReadPushEvents(
  String userId,
  Set<String> eventIds, {
  PushMediaSession? session,
  http.Client? client,
  Map<String, String> roomByEvent = const {},
  Set<String> roomIds = const {},
  void Function(String roomId)? onReadRoom,
}) async {
  final read = <String>{};
  final scopedRooms = {...roomByEvent.values, ...roomIds};
  if (eventIds.isEmpty && scopedRooms.isEmpty) return read;
  http.Client? ownedClient;
  try {
    final media = session ?? await loadPushMediaSession(userId);
    if (media == null) return read;
    final transport = client ?? (ownedClient = http.Client());
    final base = media.homeserver.trim().replaceFirst(RegExp(r'/+$'), '');
    final unresolved = eventIds.toSet();
    if (scopedRooms.isNotEmpty) {
      // A fresh, filtered sync also covers fully read rooms whose old events
      // are outside the recent notification pages. Never use a queued badge
      // or a stale foreground room count to decide this in the background.
      try {
        final uri = Uri.parse('$base/_matrix/client/v3/sync').replace(
          queryParameters: {
            'timeout': '0',
            'filter': jsonEncode({
              'room': {
                'rooms': scopedRooms.toList(),
                'timeline': {'limit': 0},
                'state': {'types': []},
                'ephemeral': {'types': []},
                'account_data': {'types': []},
              },
              'presence': {'types': []},
              'account_data': {'types': []},
            }),
          },
        );
        final response = await transport
            .get(uri, headers: {'Authorization': 'Bearer ${media.accessToken}'})
            .timeout(const Duration(seconds: 5));
        if (response.statusCode == 200) {
          final body = jsonDecode(response.body);
          final rooms = body is Map<String, dynamic> ? body['rooms'] : null;
          final joined = rooms is Map<String, dynamic> ? rooms['join'] : null;
          if (joined is Map<String, dynamic>) {
            final readRooms = <String>{};
            for (final roomId in scopedRooms) {
              final room = joined[roomId];
              final counts = room is Map<String, dynamic>
                  ? room['unread_notifications']
                  : null;
              if (counts is Map<String, dynamic> &&
                  counts['notification_count'] == 0) {
                readRooms.add(roomId);
                onReadRoom?.call(roomId);
              }
            }
            for (final entry in roomByEvent.entries) {
              if (unresolved.contains(entry.key) &&
                  readRooms.contains(entry.value)) {
                read.add(entry.key);
                unresolved.remove(entry.key);
              }
            }
          }
        }
      } catch (error) {
        debugPrint('Push room read check failed: ${error.runtimeType}');
      }
    }
    String? from;
    // Bound background work. Events outside these pages remain unknown;
    // persisted read IDs and later sync updates still cover their cleanup.
    for (var page = 0; page < 3 && unresolved.isNotEmpty; page++) {
      final uri = Uri.parse(
        '$base/_matrix/client/v3/notifications',
      ).replace(queryParameters: {'limit': '100', 'from': ?from});
      final response = await transport
          .get(uri, headers: {'Authorization': 'Bearer ${media.accessToken}'})
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        debugPrint('Push read check rejected: HTTP ${response.statusCode}');
        break;
      }
      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic> || body['notifications'] is! List) {
        break;
      }
      for (final notification in body['notifications'] as List) {
        if (notification is! Map<String, dynamic>) continue;
        final event = notification['event'];
        final id = event is Map<String, dynamic> ? event['event_id'] : null;
        if (id is! String || !unresolved.contains(id)) continue;
        if (notification['read'] == true) read.add(id);
        if (notification['read'] is bool) unresolved.remove(id);
      }
      final next = body['next_token'];
      if (next is! String || next.isEmpty || next == from) break;
      from = next;
    }
  } catch (error) {
    debugPrint('Push read check failed: ${error.runtimeType}');
  } finally {
    ownedClient?.close();
  }
  return read;
}
