import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Facts the notification path needs that the Matrix push payload does not
/// carry: whether a room is a direct chat, and its display name and avatar.
///
/// The gateway sends `room_name`, but that is empty for unnamed rooms and
/// there is no group/direct flag in the push gateway API at all, so an
/// unassisted payload cannot tell a direct chat from a group.
class PushRoomInfo {
  const PushRoomInfo({required this.name, required this.isDirect});

  final String name;
  final bool isDirect;

  factory PushRoomInfo.fromJson(Map<String, dynamic> json) => PushRoomInfo(
    name: json['name'] as String? ?? '',
    isDirect: json['is_direct'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {'name': name, 'is_direct': isDirect};
}

String pushRoomDirectoryKey(String userId) =>
    'push_rooms_${base64Url.encode(utf8.encode(userId))}';

/// Read-only view used by the notification path.
///
/// The FCM background isolate cannot reach Riverpod or the running Rust
/// client, so it reads the snapshot the foreground app keeps fresh.
class PushRoomDirectory {
  /// Last decoded snapshot per account, retaining the raw JSON it came from so
  /// a renamed room is picked up instead of serving a stale title forever. One
  /// device can hold several accounts, so the account is part of the key.
  final Map<String, ({String? raw, Map<String, PushRoomInfo> rooms})> _cache =
      {};

  Future<Map<String, PushRoomInfo>> _roomsFor(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(pushRoomDirectoryKey(userId));
    final cached = _cache[userId];
    if (cached != null && cached.raw == raw) return cached.rooms;

    final rooms = <String, PushRoomInfo>{};
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        for (final entry in decoded.entries) {
          if (entry.value case final Map<String, dynamic> value) {
            rooms[entry.key] = PushRoomInfo.fromJson(value);
          }
        }
      } on FormatException {
        // A corrupt snapshot only costs richer titles, never delivery.
      }
    }
    _cache[userId] = (raw: raw, rooms: rooms);
    return rooms;
  }

  Future<PushRoomInfo?> lookup(String userId, String roomId) async =>
      (await _roomsFor(userId))[roomId];

  /// Drop an account's cached snapshot so a removed or re-signed-in account
  /// never renders notifications from stale room metadata.
  void forget(String userId) => _cache.remove(userId);
}

/// Persist the joined-room snapshot the push path reads.
Future<void> savePushRoomDirectory(
  String userId,
  Iterable<({String id, String name, String roomType})> rooms,
) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    pushRoomDirectoryKey(userId),
    jsonEncode({
      for (final room in rooms)
        room.id: PushRoomInfo(
          name: room.name,
          isDirect: room.roomType == 'dm',
        ).toJson(),
    }),
  );
}

/// Drop the snapshot when an account is removed, so a reinstalled account
/// cannot render notifications from stale room metadata.
Future<void> clearPushRoomDirectory(String userId) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(pushRoomDirectoryKey(userId));
}
