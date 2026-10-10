import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/push/push_payload.dart';
import 'package:matter/features/push/push_room_directory.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const groupRoom = PushRoomInfo(name: '项目组', isDirect: false);
  const directRoom = PushRoomInfo(name: 'Alice', isDirect: true);

  Map<String, dynamic> event({
    String? type = 'm.room.message',
    String? sender = '@alice:example.org',
    String? senderDisplayName = 'Alice',
    String? roomName,
    Object? body = '明天的会改到 10 点',
    String? msgType = 'm.text',
    String? contentType,
  }) => {
    'room_id': '!room:example.org',
    'event_id': r'$event',
    'type': ?type,
    'sender': ?sender,
    'sender_display_name': ?senderDisplayName,
    'room_name': ?roomName,
    'content_body': ?body,
    'content_msgtype': ?msgType,
    'content': ?contentType,
  };

  group('group chat', () {
    test('titles with the room and prefixes the sender in the body', () {
      final preview = buildPushPreview(event(roomName: '项目组'), room: groupRoom);
      expect(preview.title, '项目组');
      expect(preview.body, 'Alice：明天的会改到 10 点');
      expect(preview.groupTitle, '项目组');
    });

    test('falls back to the payload room_name without a directory entry', () {
      final preview = buildPushPreview(event(roomName: '项目组'));
      expect(preview.title, '项目组');
      // Without room metadata the direct-chat flag is unknown, so the sender
      // prefix is the safe choice: an unlabelled body is unreadable in groups.
      expect(preview.body, 'Alice：明天的会改到 10 点');
    });

    test('uses the sender localpart when no display name was sent', () {
      final preview = buildPushPreview(
        event(senderDisplayName: null),
        room: groupRoom,
      );
      expect(preview.body, 'alice：明天的会改到 10 点');
    });

    test('shows sender-less events without an empty prefix', () {
      final preview = buildPushPreview(
        event(sender: null, senderDisplayName: null),
        room: groupRoom,
      );
      expect(preview.body, '明天的会改到 10 点');
      expect(preview.title, '项目组');
    });

    test('describes non-text messages by type', () {
      for (final (msgType, expected) in [
        ('m.image', 'Alice：发送了一张图片'),
        ('m.video', 'Alice：发送了视频'),
        ('m.audio', 'Alice：发送了音频'),
        ('m.file', 'Alice：发送了文件'),
        ('m.location', 'Alice：发送了位置'),
      ]) {
        final preview = buildPushPreview(
          event(msgType: msgType, body: null),
          room: groupRoom,
        );
        expect(preview.body, expected, reason: msgType);
      }
    });

    test('keeps a caption when the gateway sent one', () {
      final preview = buildPushPreview(
        event(msgType: 'm.image', body: '看这个'),
        room: groupRoom,
      );
      expect(preview.body, 'Alice：看这个');
    });

    test('sticks to the sender name when the room is unnamed everywhere', () {
      final preview = buildPushPreview(
        event(),
        room: const PushRoomInfo(name: '', isDirect: false),
      );
      expect(preview.title, 'Alice');
    });
  });

  group('direct chat', () {
    test('shows the message without repeating the sender', () {
      final preview = buildPushPreview(
        event(roomName: 'Alice'),
        room: directRoom,
      );
      expect(preview.title, 'Alice');
      expect(preview.body, '明天的会改到 10 点');
    });

    test('falls back to the sender name when the room is unnamed', () {
      final preview = buildPushPreview(event(), room: directRoom);
      expect(preview.title, 'Alice');
      expect(preview.body, '明天的会改到 10 点');
    });
  });

  group('encrypted events', () {
    test('names the sender but never fabricates content', () {
      final preview = buildPushPreview(
        event(type: 'm.room.encrypted', body: null, msgType: null),
        room: groupRoom,
      );
      expect(preview.title, '项目组');
      expect(preview.body, 'Alice：已加密的消息');
    });

    test('still shows the room name when a direct chat', () {
      final preview = buildPushPreview(
        event(type: 'm.room.encrypted', body: null, msgType: null),
        room: directRoom,
      );
      expect(preview.title, 'Alice');
      expect(preview.body, 'Alice：已加密的消息');
    });

    test('ignores ciphertext that happens to look like a body', () {
      final preview = buildPushPreview(
        event(type: 'm.room.encrypted', body: 'AwgAEnB1ZXN0...', msgType: null),
        room: groupRoom,
      );
      expect(preview.body, 'Alice：已加密的消息');
    });
  });

  group('non-message events', () {
    test('stay generic and never repeat the sender in the body', () {
      for (final type in ['m.room.member', 'm.reaction', 'm.call.invite']) {
        final preview = buildPushPreview(
          event(type: type, body: null, msgType: null),
          room: groupRoom,
        );
        expect(preview.title, '项目组', reason: type);
        expect(preview.body, genericBody, reason: type);
      }
    });
  });

  group('payload encodings', () {
    test('reads nested JSON content over flattened fields', () {
      final preview = buildPushPreview(
        event(
          body: '展开正文',
          msgType: 'm.text',
          contentType: jsonEncode({'msgtype': 'm.text', 'body': '对象正文'}),
        ),
        room: groupRoom,
      );
      expect(preview.body, 'Alice：对象正文');
    });

    test('accepts an unparsable content string by using flattened fields', () {
      final preview = buildPushPreview(
        event(contentType: 'not json'),
        room: groupRoom,
      );
      expect(preview.body, 'Alice：明天的会改到 10 点');
    });

    test('treats blank and non-string fields as absent', () {
      // Direct chat so the sender prefix does not obscure the fallback under
      // test: the point is that a blank body and a numeric msgtype are dropped.
      final preview = buildPushPreview({
        ...event(msgType: null),
        'content_body': '   ',
        'content_msgtype': 42,
      }, room: directRoom);
      expect(preview.body, genericBody);
    });

    test('falls back to the sender localpart for a blank display name', () {
      final preview = buildPushPreview(
        event(senderDisplayName: '   '),
        room: groupRoom,
      );
      expect(preview.body, 'alice：明天的会改到 10 点');
    });
  });

  group('PushRoomDirectory', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('round-trips the room snapshot the foreground writes', () async {
      await savePushRoomDirectory('@alice:example.org', [
        (id: '!group:example.org', name: '项目组', roomType: 'group'),
        (id: '!dm:example.org', name: 'Alice', roomType: 'dm'),
      ]);
      final directory = PushRoomDirectory();
      final groupInfo = await directory.lookup(
        '@alice:example.org',
        '!group:example.org',
      );
      final directInfo = await directory.lookup(
        '@alice:example.org',
        '!dm:example.org',
      );
      expect(groupInfo?.name, '项目组');
      expect(groupInfo?.isDirect, false);
      expect(directInfo?.isDirect, true);
    });

    test('returns null for unknown rooms and corrupt snapshots', () async {
      SharedPreferences.setMockInitialValues({
        pushRoomDirectoryKey('@alice:example.org'): 'not json',
      });
      final directory = PushRoomDirectory();
      expect(
        await directory.lookup('@alice:example.org', '!unknown:example.org'),
        isNull,
      );
    });

    test('keeps accounts isolated from one another', () async {
      await savePushRoomDirectory('@alice:example.org', [
        (id: '!room:example.org', name: 'Alice 的房间', roomType: 'group'),
      ]);
      final directory = PushRoomDirectory();
      expect(
        await directory.lookup('@bob:example.org', '!room:example.org'),
        isNull,
      );
      expect(
        (await directory.lookup(
          '@alice:example.org',
          '!room:example.org',
        ))?.name,
        'Alice 的房间',
      );
    });

    test('clearing an account drops its snapshot', () async {
      await savePushRoomDirectory('@alice:example.org', [
        (id: '!room:example.org', name: '项目组', roomType: 'group'),
      ]);
      await clearPushRoomDirectory('@alice:example.org');
      expect(
        await PushRoomDirectory().lookup(
          '@alice:example.org',
          '!room:example.org',
        ),
        isNull,
      );
    });
  });
}
