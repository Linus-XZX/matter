import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How many room conversations keep accumulated messages.
const _maxTrackedRooms = 24;

/// How many messages one notification shows. Android collapses long
/// conversations anyway, so keeping more only grows the stored payload.
const maxMessagesPerConversation = 7;

/// One received message inside a room's notification conversation.
class PushConversationEntry {
  const PushConversationEntry({
    required this.senderId,
    required this.senderName,
    required this.body,
    required this.eventId,
    required this.receivedAtMillis,
    this.eventType = '',
    this.roomName = '',
  });

  final String senderId;
  final String senderName;
  final String body;
  final String eventId;
  final int receivedAtMillis;
  final String eventType;
  final String roomName;

  factory PushConversationEntry.fromJson(Map<String, dynamic> json) =>
      PushConversationEntry(
        senderId: json['sender_id'] as String? ?? '',
        senderName: json['sender_name'] as String? ?? '',
        body: json['body'] as String? ?? '',
        eventId: json['event_id'] as String? ?? '',
        receivedAtMillis: json['received_at'] as int? ?? 0,
        // Missing legacy metadata must not make encrypted messages replyable.
        eventType: json['event_type'] as String? ?? '',
        roomName: json['room_name'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
    'sender_id': senderId,
    'sender_name': senderName,
    'body': body,
    'event_id': eventId,
    'received_at': receivedAtMillis,
    'event_type': eventType,
    'room_name': roomName,
  };
}

/// Accumulated notification state for one room.
class PushConversation {
  const PushConversation({
    required this.entries,
    required this.latestEventId,
    required this.updatedAtMillis,
  });

  /// Oldest first, as Android expects for messaging style.
  final List<PushConversationEntry> entries;

  /// Newest event, used to decide whether a read receipt already covers it.
  final String latestEventId;

  final int updatedAtMillis;

  factory PushConversation.fromJson(Map<String, dynamic> json) =>
      PushConversation(
        entries: [
          for (final entry in json['entries'] as List? ?? const [])
            if (entry is Map<String, dynamic>)
              PushConversationEntry.fromJson(entry),
        ],
        latestEventId: json['latest_event_id'] as String? ?? '',
        updatedAtMillis: json['updated_at'] as int? ?? 0,
      );

  Map<String, dynamic> toJson() => {
    'entries': [for (final entry in entries) entry.toJson()],
    'latest_event_id': latestEventId,
    'updated_at': updatedAtMillis,
  };

  /// Append [entry], dropping the oldest messages past the display cap.
  PushConversation append(PushConversationEntry entry) {
    final all = [...entries, entry];
    return PushConversation(
      entries: all.length > maxMessagesPerConversation
          ? all.sublist(all.length - maxMessagesPerConversation)
          : all,
      latestEventId: entry.eventId,
      updatedAtMillis: entry.receivedAtMillis,
    );
  }
}

String pushConversationsKey(String userId) =>
    'push_conversations_${base64Url.encode(utf8.encode(userId))}';

String pushReadEventsKey(String userId) =>
    'push_read_events_${base64Url.encode(utf8.encode(userId))}';

/// Stable Android notification identity for one room.
///
/// Android identifies a notification by `(tag, id)`. Both parts must therefore
/// stay constant for a room, otherwise every message posts a new notification
/// instead of updating the conversation in place. The event id travels in the
/// payload instead, which Android does not use for identity.
String pushRoomTag({
  required String userId,
  required String roomId,
  required String registrationId,
}) => jsonEncode({
  'user_id': userId,
  'room_id': roomId,
  'registration_id': registrationId,
});

int pushRoomNotificationId(String userId, String roomId) {
  final bytes = sha256.convert(utf8.encode('$userId\n$roomId')).bytes;
  return ((bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]) &
      0x7fffffff;
}

/// Persist accumulated conversations for the background isolate to update.
///
/// The FCM background isolate gets a fresh engine per message and cannot reach
/// the foreground state, so the conversation is rebuilt from this store each
/// time a message arrives.
class PushConversationStore {
  // Serialize account writes in an engine. Persisted read IDs also filter out
  // stale history written by another engine after a read was confirmed.
  static final _writes = <String, Future<void>>{};

  Future<T> _write<T>(String userId, Future<T> Function() action) {
    final result = (_writes[userId] ?? Future<void>.value()).then(
      (_) => action(),
    );
    final tail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    _writes[userId] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_writes[userId], tail)) _writes.remove(userId);
      }),
    );
    return result;
  }

  Set<String> _readEvents(SharedPreferences prefs, String userId) =>
      (prefs.getStringList(pushReadEventsKey(userId)) ?? []).toSet();

  PushConversation? _unread(PushConversation conversation, Set<String> read) {
    final entries = conversation.entries
        .where((entry) => !read.contains(entry.eventId))
        .toList();
    if (entries.isEmpty) return null;
    return PushConversation(
      entries: entries,
      latestEventId: entries.last.eventId,
      updatedAtMillis: entries.last.receivedAtMillis,
    );
  }

  Future<Map<String, dynamic>> _loadRaw(
    SharedPreferences prefs,
    String userId,
  ) async {
    await prefs.reload();
    final raw = prefs.getString(pushConversationsKey(userId));
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : {};
    } on FormatException {
      // A corrupt store only costs accumulated history, never delivery.
      return {};
    }
  }

  Future<PushConversation?> load(String userId, String roomId) async {
    await _writes[userId];
    final prefs = await SharedPreferences.getInstance();
    final raw = await _loadRaw(prefs, userId);
    final room = raw[roomId];
    return room is Map<String, dynamic>
        ? _unread(PushConversation.fromJson(room), _readEvents(prefs, userId))
        : null;
  }

  Future<Map<String, PushConversation>> all(String userId) async {
    await _writes[userId];
    final prefs = await SharedPreferences.getInstance();
    final raw = await _loadRaw(prefs, userId);
    final read = _readEvents(prefs, userId);
    return {
      for (final entry in raw.entries)
        if (entry.value case final Map<String, dynamic> value)
          entry.key: ?_unread(PushConversation.fromJson(value), read),
    };
  }

  Future<bool> wasRead(String userId, String eventId) async {
    await _writes[userId];
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return _readEvents(prefs, userId).contains(eventId);
  }

  /// Remember the confirmed read even if Android's notification was dismissed.
  Future<void> markRead(
    String userId,
    String roomId,
    Iterable<String> eventIds,
  ) => _write(userId, () async {
    if (eventIds.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = await _loadRaw(prefs, userId);
    final read = _readEvents(prefs, userId)..addAll(eventIds);
    // Older delayed pushes can still be checked against the homeserver.
    final retained = read.toList();
    await prefs.setStringList(
      pushReadEventsKey(userId),
      retained.length > 512
          ? retained.sublist(retained.length - 512)
          : retained,
    );
    if (raw[roomId] case final Map<String, dynamic> value) {
      final remaining = _unread(PushConversation.fromJson(value), read);
      if (remaining == null) {
        raw.remove(roomId);
      } else {
        raw[roomId] = remaining.toJson();
      }
      await prefs.setString(pushConversationsKey(userId), jsonEncode(raw));
    }
  });

  /// Add [entry] to its room conversation and return the merged result.
  Future<PushConversation> append(
    String userId,
    String roomId,
    PushConversationEntry entry,
  ) => _write(userId, () async {
    final prefs = await SharedPreferences.getInstance();
    final raw = await _loadRaw(prefs, userId);
    final read = _readEvents(prefs, userId);
    final room = raw[roomId];
    final existing =
        (room is Map<String, dynamic>
            ? _unread(PushConversation.fromJson(room), read)
            : null) ??
        const PushConversation(
          entries: [],
          latestEventId: '',
          updatedAtMillis: 0,
        );
    if (read.contains(entry.eventId)) return existing;
    final merged = existing.append(entry);
    raw[roomId] = merged.toJson();

    // Bound growth by dropping the rooms that went quiet longest ago.
    if (raw.length > _maxTrackedRooms) {
      final byAge = raw.entries.toList()
        ..sort((a, b) {
          int updated(MapEntry<String, dynamic> entry) {
            final value = entry.value;
            return value is Map<String, dynamic>
                ? value['updated_at'] as int? ?? 0
                : 0;
          }

          return updated(b).compareTo(updated(a));
        });
      raw
        ..clear()
        ..addEntries(byAge.take(_maxTrackedRooms));
    }

    await prefs.setString(pushConversationsKey(userId), jsonEncode(raw));
    return merged;
  });

  /// Drop one room's conversation, e.g. once every message has been read.
  Future<void> clearRoom(String userId, String roomId) =>
      _write(userId, () async {
        final prefs = await SharedPreferences.getInstance();
        final raw = await _loadRaw(prefs, userId);
        if (raw.remove(roomId) == null) return;
        await prefs.setString(pushConversationsKey(userId), jsonEncode(raw));
      });

  Future<void> clearAccount(String userId) => _write(userId, () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(pushConversationsKey(userId));
    await prefs.remove(pushReadEventsKey(userId));
  });
}
