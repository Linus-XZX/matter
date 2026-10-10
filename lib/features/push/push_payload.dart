import 'dart:convert';

import 'push_room_directory.dart';

/// Decides the notification title, body and grouping for one Matrix push.
///
/// Kept free of Flutter and plugin imports so both the Android runtime and the
/// browser worker can be driven by the same rules and unit-tested directly.
class PushPreview {
  const PushPreview({
    required this.title,
    required this.body,
    required this.groupTitle,
  });

  /// Notification title: the room name, falling back to the sender.
  final String title;

  /// Notification body: `Sender：message` in groups, message alone in a chat.
  final String body;

  /// Conversation label used for messaging-style grouping.
  final String groupTitle;
}

const genericBody = '你有一条新消息';
const encryptedGroupBody = '已加密的消息';
const genericTitle = 'Matter';

const _stickerHint = '发送了一个贴纸';
const _imageHint = '发送了一张图片';
const _videoHint = '发送了视频';
const _audioHint = '发送了音频';
const _fileHint = '发送了文件';
const _locationHint = '发送了位置';

String? _nonEmptyString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// FCM HTTP v1 flattens event content into `content_*` fields; legacy FCM and
/// Web Push send `content` as a JSON object or a JSON string.
Map<String, dynamic>? _content(Map<String, dynamic> data) {
  final raw = data['content'];
  if (raw is Map<String, dynamic>) return raw;
  if (raw is String) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }
  return null;
}

String? _msgType(Map<String, dynamic> data, Map<String, dynamic>? content) =>
    _nonEmptyString(content?['msgtype']) ?? _nonEmptyString(data['content_msgtype']);

String? _messageBody(Map<String, dynamic> data, Map<String, dynamic>? content) =>
    _nonEmptyString(content?['body']) ?? _nonEmptyString(data['content_body']);

/// Sender name is display name when the homeserver provided one, else the
/// localpart of the sender MXID.
String? _senderName(Map<String, dynamic> data) {
  final displayName = _nonEmptyString(data['sender_display_name']);
  if (displayName != null) return displayName;
  final sender = _nonEmptyString(data['sender']);
  if (sender == null) return null;
  final localpart = sender.startsWith('@')
      ? sender.substring(1).split(':').first
      : sender;
  return localpart.isEmpty ? null : localpart;
}

String? _bodyForType(String? msgType, String? body) {
  switch (msgType) {
    case 'm.sticker':
      return body ?? _stickerHint;
    case 'm.image':
      return body ?? _imageHint;
    case 'm.video':
      return body ?? _videoHint;
    case 'm.audio':
      return body ?? _audioHint;
    case 'm.file':
      return body ?? _fileHint;
    case 'm.location':
      return body ?? _locationHint;
    default:
      return body;
  }
}

/// Whether the event is a message whose content we are able to describe.
bool isMessageEvent(Map<String, dynamic> data) {
  final type = _nonEmptyString(data['type']);
  return type == 'm.room.message' || type == 'm.sticker';
}

bool isEncryptedEvent(Map<String, dynamic> data) =>
    _nonEmptyString(data['type']) == 'm.room.encrypted';

/// Build the notification title and body from a gateway payload.
///
/// [room] supplies the direct-chat flag and a name for rooms the gateway left
/// unnamed; it is optional because the payload alone still yields a usable
/// notification.
PushPreview buildPushPreview(
  Map<String, dynamic> data, {
  PushRoomInfo? room,
}) {
  final roomName =
      _nonEmptyString(room?.name) ?? _nonEmptyString(data['room_name']);
  final sender = _senderName(data);
  final isDirect = room?.isDirect ?? false;

  // Title prefers the room, which covers both a group name and the peer name
  // a homeserver reports for a direct chat.
  final title = roomName ?? sender ?? genericTitle;

  String body;
  if (isEncryptedEvent(data)) {
    // The body is ciphertext; the sender is plaintext envelope metadata the
    // gateway already received, so quoting it reveals nothing new.
    body = sender == null ? genericBody : '$sender：$encryptedGroupBody';
  } else if (isMessageEvent(data)) {
    final content = _content(data);
    final text =
        _bodyForType(_msgType(data, content), _messageBody(data, content)) ??
        genericBody;
    body = text;
  } else {
    body = genericBody;
  }

  // A direct chat shows the message alone: the title already names the peer
  // and repeating the sender would be noise.
  if (!isDirect && sender != null && isMessageEvent(data)) {
    body = '$sender：$body';
  }

  return PushPreview(
    title: title,
    body: body,
    groupTitle: roomName ?? title,
  );
}
