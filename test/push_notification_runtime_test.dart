import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/push/fcm_push_runtime.dart';
import 'package:matter/features/push/firebase_client_config.dart';
import 'package:matter/features/push/push_conversation.dart';
import 'package:matter/features/push/push_providers.dart';
import 'package:matter/features/push/push_room_directory.dart';
import 'package:matter/features/push/push_runtime.dart';
import 'package:matter/features/push/push_settings.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ReadApi implements RustLibApi {
  Completer<bool>? pending;
  Object? error;

  @override
  Future<bool> crateApiMatrixMarkRoomAsRead({
    required String accountUserId,
    required String roomId,
    required bool explicit,
  }) async {
    if (error case final failure?) throw failure;
    return pending?.future ?? false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  const target = PushTarget(
    userId: '@alice:example.org',
    roomId: '!room:example.org',
    eventId: r'$event',
    registrationId: 'current',
  );
  final calls = <MethodCall>[];
  var active = <Map<String, dynamic>>[];
  final api = _ReadApi();
  setUpAll(() => RustLib.initMock(api: api));
  tearDownAll(RustLib.dispose);

  setUp(() {
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    fcmPushRuntime.configuration = const FirebaseClientConfig(
      apiKey: 'test',
      appId: 'test',
      senderId: 'test',
      projectId: 'test',
    );
    SharedPreferences.setMockInitialValues({
      pushSettingsKey(target.userId): jsonEncode(
        const PushSettings(enabled: true, registrationId: 'current').toJson(),
      ),
      'multi_sessions': jsonEncode([
        {'user_id': target.userId},
      ]),
    });
    calls.clear();
    api.pending = null;
    api.error = null;
    active = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'getActiveNotifications') return active;
          return null;
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    fcmPushRuntime.configuration = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'focused Matter suppresses notifications, unfocused Matter shows them',
    () async {
      final notifications = FlutterLocalNotificationsPlugin();
      await showMatrixPush(
        notifications,
        target.toData(),
        isFocused: () => true,
      );
      expect(calls.where((call) => call.method == 'show'), isEmpty);
      await showMatrixPush(
        notifications,
        target.toData(),
        isFocused: () => false,
      );
      expect(calls.where((call) => call.method == 'show'), hasLength(1));
    },
  );

  test(
    'plain messages show JSON-encoded FCM content; encrypted content stays generic',
    () async {
      final notifications = FlutterLocalNotificationsPlugin();
      for (final type in ['m.room.message', 'm.room.encrypted', null]) {
        await showMatrixPush(notifications, {
          ...target.toData(),
          'type': type,
          'content': jsonEncode({'body': '消息正文'}),
          'content_body': '展开后的正文',
        });
        final args = calls.last.arguments as Map;
        expect(
          args['body'],
          switch (type) {
            'm.room.message' => '消息正文',
            // Ciphertext is never rendered as a body.
            'm.room.encrypted' => '已加密的消息',
            _ => '你有一条新消息',
          },
        );
      }
    },
  );

  test('group messages title with the room and name the sender', () async {
    final notifications = FlutterLocalNotificationsPlugin();
    await showMatrixPush(notifications, {
      ...target.toData(),
      'type': 'm.room.message',
      'room_name': '项目组',
      'sender': '@alice:example.org',
      'sender_display_name': 'Alice',
      'content_body': '明天的会改到 10 点',
      'content_msgtype': 'm.text',
    });
    final args = calls.last.arguments as Map;
    expect(args['title'], '项目组');
    expect(args['body'], 'Alice：明天的会改到 10 点');
  });

  test('encrypted group events name the sender without a body', () async {
    final notifications = FlutterLocalNotificationsPlugin();
    await showMatrixPush(notifications, {
      ...target.toData(),
      'type': 'm.room.encrypted',
      'room_name': '项目组',
      'sender': '@alice:example.org',
      'sender_display_name': 'Alice',
    });
    final args = calls.last.arguments as Map;
    expect(args['title'], '项目组');
    expect(args['body'], 'Alice：已加密的消息');
  });

  test('a direct chat drops the sender prefix and groups per room', () async {
    await savePushRoomDirectory(target.userId, [
      (id: target.roomId, name: 'Alice', roomType: 'dm'),
    ]);
    final notifications = FlutterLocalNotificationsPlugin();
    await showMatrixPush(notifications, {
      ...target.toData(),
      'type': 'm.room.message',
      'sender': '@alice:example.org',
      'sender_display_name': 'Alice',
      'content_body': '在吗',
      'content_msgtype': 'm.text',
    });
    final args = calls.last.arguments as Map;
    expect(args['title'], 'Alice');
    expect(args['body'], '在吗');
    // Keyed by room so Android collapses one conversation together; the old
    // account-wide key would merge every room into a single stack.
    final specifics = args['platformSpecifics'] as Map;
    expect(specifics['groupKey'], 'matrix:${target.userId}:${target.roomId}');
  });

  test('the same room aggregates successive messages into one notification', () async {
    final notifications = FlutterLocalNotificationsPlugin();
    Map<String, dynamic> message(String eventId, String sender, String body) => {
      ...target.toData(),
      'event_id': eventId,
      'type': 'm.room.message',
      'room_name': '项目组',
      'sender': sender,
      'sender_display_name': sender.contains('alice') ? 'Alice' : 'Bob',
      'content_body': body,
      'content_msgtype': 'm.text',
    };

    await showMatrixPush(
      notifications,
      message(r'$one', '@alice:example.org', '第一条'),
    );
    await showMatrixPush(
      notifications,
      message(r'$two', '@bob:example.org', '第二条'),
    );

    final shows = calls.where((call) => call.method == 'show').toList();
    expect(shows, hasLength(2));
    final first = shows.first.arguments as Map;
    final second = shows.last.arguments as Map;
    // A stable (tag, id) per room is what makes Android update in place
    // rather than stack a separate notification per message.
    expect(second['id'], first['id']);
    final firstSpecifics = first['platformSpecifics'] as Map;
    final secondSpecifics = second['platformSpecifics'] as Map;
    expect(secondSpecifics['tag'], firstSpecifics['tag']);
    expect(firstSpecifics['tag'], isNot(contains(r'$one')));
    // The latest event travels in the payload, which Android ignores for
    // identity but read-receipt cleanup relies on.
    expect(second['payload'], contains(r'$two'));
    final style = secondSpecifics['styleInformation'] as Map;
    expect(style['messages'], hasLength(2));
    expect(
      (style['messages'] as List)
          .map((entry) => (entry as Map)['text'])
          .toList(),
      ['第一条', '第二条'],
    );
    // Each entry is labelled by its own author, so the text stays prefix-free.
    final authors = [
      for (final entry in (style['messages'] as List))
        ((entry as Map)['person'] as Map)['name'],
    ];
    expect(authors, ['Alice', 'Bob']);
  });

  test('a read room also drops its accumulated conversation', () async {
    active = [
      {'id': 1, 'tag': jsonEncode(target.toData())},
    ];
    await showMatrixPush(FlutterLocalNotificationsPlugin(), {
      ...target.toData(),
      'type': 'm.room.message',
      'sender': '@alice:example.org',
      'sender_display_name': 'Alice',
      'content_body': '在吗',
      'content_msgtype': 'm.text',
    });
    await fcmPushRuntime.cancelRoomNotifications(
      target.userId,
      target.roomId,
      [target.eventId],
    );
    // Otherwise the next message would resurrect everything already read.
    expect(
      await PushConversationStore().load(target.userId, target.roomId),
      isNull,
    );
  });

  test(
    'Sygnal FCM v1 content_body is shown only for plaintext events',
    () async {
      final notifications = FlutterLocalNotificationsPlugin();
      for (final type in [
        'm.room.message',
        'm.sticker',
        'm.room.encrypted',
        'm.room.member',
        null,
      ]) {
        await showMatrixPush(notifications, {
          ...target.toData(),
          'type': type,
          'content_body': 'Sygnal 消息正文',
          'content_msgtype': 'm.text',
        });
        final args = calls.last.arguments as Map;
        expect(
          args['body'],
          switch (type) {
            'm.room.message' || 'm.sticker' => 'Sygnal 消息正文',
            'm.room.encrypted' => '已加密的消息',
            _ => '你有一条新消息',
          },
        );
      }
    },
  );

  test('content_body is used when nested content has no usable body', () async {
    final notifications = FlutterLocalNotificationsPlugin();
    for (final content in [
      null,
      'invalid json',
      jsonEncode({'body': '  '}),
      {'body': 42},
      {'msgtype': 'm.text'},
    ]) {
      await showMatrixPush(notifications, {
        ...target.toData(),
        'type': 'm.room.message',
        'content': content,
        'content_body': 'Sygnal 消息正文',
      });
      expect((calls.last.arguments as Map)['body'], 'Sygnal 消息正文');
    }
  });

  test('missing or invalid content_body keeps the generic notice', () async {
    final notifications = FlutterLocalNotificationsPlugin();
    for (final body in [
      null,
      '',
      '  ',
      42,
      {'body': 'not a string'},
    ]) {
      await showMatrixPush(notifications, {
        ...target.toData(),
        'type': 'm.room.message',
        'content_body': body,
      });
      expect((calls.last.arguments as Map)['body'], '你有一条新消息');
    }
  });

  test(
    'successful receipts cancel notifications even without a marked-unread flag',
    () async {
      active = [
        {'id': 1, 'tag': jsonEncode(target.toData())},
      ];
      final result = await markRoomAsReadWithPushCleanup(
        accountUserId: target.userId,
        roomId: target.roomId,
        explicit: false,
      );
      expect(result, false);
      expect(calls.where((call) => call.method == 'cancel'), hasLength(1));
    },
  );

  test(
    'notifications arriving during a receipt write survive its completion',
    () async {
      active = [
        {'id': 1, 'tag': jsonEncode(target.toData())},
      ];
      api.pending = Completer<bool>();
      final read = markRoomAsReadWithPushCleanup(
        accountUserId: target.userId,
        roomId: target.roomId,
        explicit: true,
      );
      await pumpEventQueue();
      expect(calls.where((call) => call.method == 'cancel'), isEmpty);
      active.add({
        'id': 2,
        'tag': jsonEncode({...target.toData(), 'event_id': r'$arriving'}),
      });
      api.pending!.complete(true);
      await read;
      final cancelled = calls.where((call) => call.method == 'cancel');
      expect(cancelled, hasLength(1));
      expect((cancelled.single.arguments as Map)['id'], 1);
    },
  );

  test(
    'synced unread count reaching zero cancels room notifications',
    () async {
      rust.ChatRoom room(int count) => rust.ChatRoom(
        id: target.roomId,
        name: 'Room',
        lastMessage: '',
        lastMessageTime: '0',
        lastEventId: target.eventId,
        unreadCount: count,
        isMarkedUnread: false,
        roomType: 'dm',
        isEncrypted: false,
        isMuted: false,
        roomState: 'joined',
      );
      var rooms = [room(1)];
      final container = ProviderContainer(
        overrides: [allChatRoomsProvider.overrideWith((ref) async => rooms)],
      );
      addTearDown(container.dispose);
      container.read(sessionReadyProvider.notifier).value = true;
      container.read(activeUserIdProvider.notifier).value = target.userId;
      container.listen(pushReadStateProvider, (_, _) {}, fireImmediately: true);
      await container.read(allChatRoomsProvider.future);
      await pumpEventQueue();
      active = [
        {'id': 1, 'tag': jsonEncode(target.toData())},
      ];
      rooms = [room(0)];
      container.invalidate(allChatRoomsProvider);
      await container.read(allChatRoomsProvider.future);
      await pumpEventQueue();
      expect(calls.where((call) => call.method == 'cancel'), hasLength(1));
    },
  );

  test('failed receipts leave notifications intact', () async {
    active = [
      {'id': 1, 'tag': jsonEncode(target.toData())},
    ];
    api.error = StateError('offline');
    await expectLater(
      markRoomAsReadWithPushCleanup(
        accountUserId: target.userId,
        roomId: target.roomId,
        explicit: true,
      ),
      throwsStateError,
    );
    expect(calls.where((call) => call.method == 'cancel'), isEmpty);
  });

  test(
    'dismissal preserves other rooms, accounts and messages arriving during read',
    () async {
      Map<String, dynamic> notification(int id, PushTarget value) => {
        'id': id,
        'tag': jsonEncode(value.toData()),
      };
      const otherRoom = PushTarget(
        userId: '@alice:example.org',
        roomId: '!other:example.org',
        eventId: r'$other',
        registrationId: 'current',
      );
      const otherAccount = PushTarget(
        userId: '@bob:example.org',
        roomId: '!room:example.org',
        eventId: r'$bob',
        registrationId: 'current',
      );
      active = [
        notification(1, target),
        notification(2, otherRoom),
        notification(3, otherAccount),
      ];
      final events = await fcmPushRuntime.roomNotificationEvents(
        target.userId,
        target.roomId,
      );
      expect(events, [target.eventId]);
      const arriving = PushTarget(
        userId: '@alice:example.org',
        roomId: '!room:example.org',
        eventId: r'$arriving',
        registrationId: 'current',
      );
      active.add(notification(4, arriving));
      await fcmPushRuntime.cancelRoomNotifications(
        target.userId,
        target.roomId,
        events,
      );
      final cancelled = calls.where((call) => call.method == 'cancel');
      expect(cancelled, hasLength(1));
      expect((cancelled.single.arguments as Map)['id'], 1);
      expect(
        (cancelled.single.arguments as Map)['tag'],
        jsonEncode(target.toData()),
      );
    },
  );
}
