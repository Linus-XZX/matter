import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matter/features/push/fcm_push_runtime.dart';
import 'package:matter/features/push/firebase_client_config.dart';
import 'package:matter/features/push/push_avatar.dart';
import 'package:matter/features/push/push_conversation.dart';
import 'package:matter/features/push/push_notification_actions.dart';
import 'package:matter/features/push/push_providers.dart';
import 'package:matter/features/push/push_room_directory.dart';
import 'package:matter/features/push/push_runtime.dart';
import 'package:matter/features/push/push_settings.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/temp_path_provider.dart';

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

  // Avatar files are written under the application support directory.
  late Directory avatarRoot;

  setUp(() {
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    avatarRoot = Directory.systemTemp.createTempSync('matter-push-avatars');
    installTempPathProvider(avatarRoot);
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
    if (avatarRoot.existsSync()) avatarRoot.deleteSync(recursive: true);
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
        expect(args['body'], switch (type) {
          'm.room.message' => '消息正文',
          // Ciphertext is never rendered as a body.
          'm.room.encrypted' => '已加密的消息',
          _ => '你有一条新消息',
        });
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
      (
        id: target.roomId,
        name: 'Alice',
        roomType: 'dm',
        avatarMxc: '',
        isEncrypted: false,
      ),
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

  test(
    'the same room aggregates successive messages into one notification',
    () async {
      final notifications = FlutterLocalNotificationsPlugin();
      Map<String, dynamic> message(
        String eventId,
        String sender,
        String body,
      ) => {
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
    },
  );

  test('a reply action is offered only for a plaintext room', () async {
    final notifications = FlutterLocalNotificationsPlugin();
    Map<String, dynamic> event() => {
      ...target.toData(),
      'type': 'm.room.message',
      'sender': '@alice:example.org',
      'sender_display_name': 'Alice',
      'content_body': '在吗',
      'content_msgtype': 'm.text',
    };

    await showMatrixPush(notifications, event());
    var specifics = calls.last.arguments as Map;
    var platform = specifics['platformSpecifics'] as Map;
    var actions = platform['actions'] as List;
    expect(actions, hasLength(3));
    expect((actions.first as Map)['id'], replyActionId);

    // A reply to an encrypted room needs the SDK's Olm session, which the
    // notification path deliberately never starts.
    await savePushRoomDirectory(target.userId, [
      (
        id: target.roomId,
        name: 'Secret',
        roomType: 'group',
        avatarMxc: '',
        isEncrypted: true,
      ),
    ]);
    await showMatrixPush(notifications, event());
    specifics = calls.last.arguments as Map;
    platform = specifics['platformSpecifics'] as Map;
    actions = platform['actions'] as List;
    expect(actions.map((action) => (action as Map)['id']), [
      markReadActionId,
      muteActionId,
    ]);
    expect(
      actions.every((action) => (action as Map)['cancelNotification'] == false),
      isTrue,
    );
  });

  test('every message retains its own sender avatar across updates', () async {
    // Seed real avatar files, otherwise the assertion would pass trivially
    // with no icons at all.
    await savePushRoomDirectory(target.userId, [
      (
        id: target.roomId,
        name: '项目组',
        roomType: 'group',
        avatarMxc: 'mxc://example.org/room',
        isEncrypted: false,
      ),
    ]);
    await savePushSenderAvatars(target.userId, {
      '@alice:example.org': 'mxc://example.org/alice',
      '@bob:example.org': 'mxc://example.org/bob',
    });
    final avatars = PushAvatarCache(
      download: (mxc) async => Uint8List.fromList([1, 2, 3]),
    );
    final roomAvatar = await avatars.ensure(
      target.userId,
      'mxc://example.org/room',
    );
    final aliceAvatar = await avatars.ensure(
      target.userId,
      'mxc://example.org/alice',
    );
    final bobAvatar = await avatars.ensure(
      target.userId,
      'mxc://example.org/bob',
    );

    final notifications = FlutterLocalNotificationsPlugin();
    Map<String, dynamic> message(String eventId, String sender) => {
      ...target.toData(),
      'event_id': eventId,
      'type': 'm.room.message',
      'sender': sender,
      'sender_display_name': sender.contains('alice') ? 'Alice' : 'Bob',
      'content_body': eventId,
      'content_msgtype': 'm.text',
    };

    final expectedAvatars = [aliceAvatar, bobAvatar, aliceAvatar];
    final senders = [
      '@alice:example.org',
      '@bob:example.org',
      '@alice:example.org',
    ];
    for (var i = 0; i < senders.length; i++) {
      await showMatrixPush(
        notifications,
        message('\$event-$i', senders[i]),
        publishShortcut: (id, title, avatarPath) async {
          // Publish the room identity before Android sees its notification.
          expect(calls.where((call) => call.method == 'show'), hasLength(i));
          expect(title, '项目组');
          expect(avatarPath, roomAvatar);
          return id;
        },
      );
      final specifics =
          (calls.last.arguments as Map)['platformSpecifics'] as Map;
      expect(specifics['largeIcon'], roomAvatar);
      expect(
        specifics['shortcutId'],
        'matrix:${target.userId}:${target.roomId}',
      );
      expect(specifics['category'], 'msg');
      final style = specifics['styleInformation'] as Map;
      final messages = (style['messages'] as List).cast<Map>();
      expect(messages, hasLength(i + 1));
      expect([
        for (final entry in messages) (entry['person'] as Map)['icon'],
      ], expectedAvatars.take(i + 1).toList());
    }
  });

  test('a missing sender avatar never borrows the room avatar', () async {
    await savePushRoomDirectory(target.userId, [
      (
        id: target.roomId,
        name: '项目组',
        roomType: 'group',
        avatarMxc: 'mxc://example.org/room',
        isEncrypted: false,
      ),
    ]);
    final avatars = PushAvatarCache(
      download: (mxc) async => Uint8List.fromList([1, 2, 3]),
    );
    final roomAvatar = await avatars.ensure(
      target.userId,
      'mxc://example.org/room',
    );
    await showMatrixPush(FlutterLocalNotificationsPlugin(), {
      ...target.toData(),
      'type': 'm.room.message',
      'sender': '@unknown:example.org',
      'sender_display_name': 'Unknown',
      'content_body': 'hello',
    });
    final specifics = (calls.last.arguments as Map)['platformSpecifics'] as Map;
    expect(specifics['largeIcon'], roomAvatar);
    final style = specifics['styleInformation'] as Map;
    final messages = (style['messages'] as List).cast<Map>();
    expect((messages.single['person'] as Map)['icon'], isNull);
  });

  test('a direct conversation publishes the peer avatar', () async {
    await savePushRoomDirectory(target.userId, [
      (
        id: target.roomId,
        name: 'Bob',
        roomType: 'dm',
        avatarMxc: 'mxc://example.org/room',
        isEncrypted: false,
      ),
    ]);
    await savePushSenderAvatars(target.userId, {
      '@bob:example.org': 'mxc://example.org/bob',
    });
    final avatars = PushAvatarCache(
      download: (mxc) async => Uint8List.fromList([1, 2, 3]),
    );
    await avatars.ensure(target.userId, 'mxc://example.org/room');
    final bobAvatar = await avatars.ensure(
      target.userId,
      'mxc://example.org/bob',
    );
    await showMatrixPush(
      FlutterLocalNotificationsPlugin(),
      {
        ...target.toData(),
        'type': 'm.room.message',
        'sender': '@bob:example.org',
        'sender_display_name': 'Bob',
        'content_body': 'hello',
      },
      publishShortcut: (id, title, avatarPath) async {
        expect(title, 'Bob');
        expect(avatarPath, bobAvatar);
        return id;
      },
    );
    final specifics = (calls.last.arguments as Map)['platformSpecifics'] as Map;
    expect(specifics['largeIcon'], bobAvatar);
    final style = specifics['styleInformation'] as Map;
    expect(style['groupConversation'], false);
    expect(style['conversationTitle'], isNull);
    final messages = (style['messages'] as List).cast<Map>();
    expect((messages.single['person'] as Map)['icon'], bobAvatar);
  });

  test(
    'unavailable shortcut metadata still delivers the notification',
    () async {
      await showMatrixPush(
        FlutterLocalNotificationsPlugin(),
        target.toData(),
        publishShortcut: (id, title, avatarPath) async => null,
      );
      final shows = calls.where((call) => call.method == 'show');
      expect(shows, hasLength(1));
      final specifics =
          (shows.single.arguments as Map)['platformSpecifics'] as Map;
      expect(specifics['shortcutId'], isNull);
    },
  );

  Future<void> installReadSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'multi_sessions',
      jsonEncode([
        {
          'user_id': target.userId,
          'homeserver_url': 'https://matrix.example.org',
        },
      ]),
    );
    FlutterSecureStorage.setMockInitialValues({
      'matrix_access_token_${base64Url.encode(utf8.encode(target.userId))}':
          'test-token',
    });
    addTearDown(() => FlutterSecureStorage.setMockInitialValues({}));
  }

  Map<String, dynamic> nativeShownNotification() {
    final show =
        calls.lastWhere((call) => call.method == 'show').arguments as Map;
    final specifics = show['platformSpecifics'] as Map;
    return {'id': show['id'], 'tag': specifics['tag']};
  }

  test(
    'room count comes from fresh sync, not an account badge or capped history',
    () async {
      final notifications = FlutterLocalNotificationsPlugin();
      for (var i = 0; i < 10; i++) {
        await showMatrixPush(notifications, {
          ...target.toData(),
          'event_id': '\$old$i',
        });
      }
      await installReadSession();
      await http.runWithClient(
        () => showMatrixPush(notifications, {
          ...target.toData(),
          'unread': '999',
        }),
        () => MockClient(
          (request) async => http.Response(
            jsonEncode(
              request.url.path.endsWith('/sync')
                  ? {
                      'rooms': {
                        'join': {
                          target.roomId: {
                            'org.matrix.msc2654.unread_count': 180,
                            'unread_notifications': {'notification_count': 125},
                          },
                        },
                      },
                    }
                  : {'notifications': []},
            ),
            200,
          ),
        ),
      );
      final specifics =
          (calls.lastWhere((call) => call.method == 'show').arguments
                  as Map)['platformSpecifics']
              as Map;
      expect(specifics['number'], 180);
      expect(specifics['subText'], '180 条未读消息');
      expect(
        ((specifics['styleInformation'] as Map)['messages'] as List),
        hasLength(7),
      );
    },
  );

  test(
    'counts-only updates refresh an existing room count without alerting',
    () async {
      await showMatrixPush(FlutterLocalNotificationsPlugin(), target.toData());
      active = [nativeShownNotification()];
      await installReadSession();
      calls.clear();
      await http.runWithClient(
        () => showMatrixPush(FlutterLocalNotificationsPlugin(), {
          'user_id': target.userId,
          'registration_id': 'current',
          'unread': '1000',
        }),
        () => MockClient(
          (request) async => http.Response(
            jsonEncode(
              request.url.path.endsWith('/sync')
                  ? {
                      'rooms': {
                        'join': {
                          target.roomId: {
                            'unread_notifications': {'notification_count': 12},
                          },
                        },
                      },
                    }
                  : {'notifications': []},
            ),
            200,
          ),
        ),
      );
      final specifics =
          (calls.lastWhere((call) => call.method == 'show').arguments
                  as Map)['platformSpecifics']
              as Map;
      expect(specifics['number'], 12);
      expect(specifics['onlyAlertOnce'], isTrue);
    },
  );

  NotificationResponse action(String id, {PushTarget? forTarget}) =>
      NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: id,
        payload: jsonEncode((forTarget ?? target).toData()),
      );

  test(
    'mark-read action preserves messages arriving during its HTTP write',
    () async {
      final notifications = FlutterLocalNotificationsPlugin();
      await showMatrixPush(notifications, target.toData());
      active = [nativeShownNotification()];
      await installReadSession();
      final started = Completer<void>();
      final receipt = Completer<void>();
      final pending = http.runWithClient(
        () => handleNotificationAction(action(markReadActionId)),
        () => MockClient((request) async {
          if (request.method == 'POST') {
            started.complete();
            await receipt.future;
          }
          return http.Response('{}', 200);
        }),
      );
      await started.future;
      await showMatrixPush(notifications, {
        ...target.toData(),
        'event_id': r'$new',
      }, fetchReadEvents: (user, ids) async => {});
      active = [nativeShownNotification()];
      receipt.complete();
      await pending;
      final remaining = await PushConversationStore().load(
        target.userId,
        target.roomId,
      );
      expect(remaining!.entries.map((entry) => entry.eventId), [r'$new']);
      expect(
        await PushConversationStore().wasRead(target.userId, target.eventId),
        isTrue,
      );
      expect(
        await PushConversationStore().wasRead(target.userId, r'$new'),
        isFalse,
      );
      expect(calls.where((call) => call.method == 'cancel'), isEmpty);
    },
  );

  test(
    'an old mark-read action does not include newer history already present',
    () async {
      final notifications = FlutterLocalNotificationsPlugin();
      for (final id in [target.eventId, r'$new']) {
        await showMatrixPush(notifications, {
          ...target.toData(),
          'event_id': id,
        });
      }
      active = [nativeShownNotification()];
      await installReadSession();
      await http.runWithClient(
        () => handleNotificationAction(action(markReadActionId)),
        () => MockClient((request) async => http.Response('{}', 200)),
      );
      expect(
        (await PushConversationStore().load(
          target.userId,
          target.roomId,
        ))!.latestEventId,
        r'$new',
      );
      expect(
        await PushConversationStore().wasRead(target.userId, r'$new'),
        isFalse,
      );
    },
  );

  test(
    'failed notification writes leave the notification and history intact',
    () async {
      await showMatrixPush(FlutterLocalNotificationsPlugin(), target.toData());
      active = [nativeShownNotification()];
      await installReadSession();
      for (final id in [markReadActionId, muteActionId]) {
        for (final failureAt in [1, 2]) {
          var requests = 0;
          await http.runWithClient(
            () => handleNotificationAction(action(id)),
            () => MockClient(
              (request) async =>
                  http.Response('{}', ++requests == failureAt ? 403 : 200),
            ),
          );
          expect(calls.where((call) => call.method == 'cancel'), isEmpty);
          expect(
            await PushConversationStore().load(target.userId, target.roomId),
            isNotNull,
          );
          expect(
            await PushConversationStore().wasRead(
              target.userId,
              target.eventId,
            ),
            isFalse,
          );
          final prefs = await SharedPreferences.getInstance();
          expect(
            prefs.containsKey(pushRoomMuteKey(target.userId, target.roomId)),
            isFalse,
          );
        }
      }
    },
  );

  test(
    'mute action withdraws its room without reading it or touching another room',
    () async {
      final notifications = FlutterLocalNotificationsPlugin();
      await showMatrixPush(notifications, target.toData());
      active = [
        nativeShownNotification(),
        {
          'id': 9,
          'tag': pushRoomTag(
            userId: target.userId,
            roomId: '!other:example.org',
            registrationId: 'current',
          ),
        },
      ];
      await installReadSession();
      await http.runWithClient(
        () => handleNotificationAction(action(muteActionId)),
        () => MockClient((request) async => http.Response('{}', 200)),
      );
      expect(calls.where((call) => call.method == 'cancel'), hasLength(1));
      expect(
        await PushConversationStore().load(target.userId, target.roomId),
        isNull,
      );
      expect(
        await PushConversationStore().wasRead(target.userId, target.eventId),
        isFalse,
      );
      calls.clear();
      active = [];
      // A queued push must stay suppressed even if server verification fails.
      await showMatrixPush(
        notifications,
        target.toData(),
        fetchReadEvents: (user, ids) async => {},
      );
      expect(calls.where((call) => call.method == 'show'), isEmpty);
    },
  );

  test(
    'a stale registration cannot trigger a server notification action',
    () async {
      await installReadSession();
      var requests = 0;
      await http.runWithClient(
        () => handleNotificationAction(
          NotificationResponse(
            notificationResponseType:
                NotificationResponseType.selectedNotificationAction,
            actionId: markReadActionId,
            payload: jsonEncode({...target.toData(), 'registration_id': 'old'}),
          ),
        ),
        () => MockClient((request) async {
          requests++;
          return http.Response('{}', 200);
        }),
      );
      expect(requests, 0);
    },
  );

  Map<String, dynamic> serverRoomState(bool muted) => {
    'rooms': {
      'join': {
        target.roomId: {
          'unread_notifications': {'notification_count': 2},
        },
      },
    },
    'account_data': {
      'events': [
        {
          'type': 'm.push_rules',
          'content': {
            'global': {
              'override': [
                if (muted)
                  {
                    'enabled': true,
                    'actions': [],
                    'conditions': [
                      {
                        'kind': 'event_match',
                        'key': 'room_id',
                        'pattern': target.roomId,
                      },
                    ],
                  },
              ],
            },
          },
        },
      ],
    },
  };

  test(
    'a server mute withdraws queued notifications without recording reads',
    () async {
      await showMatrixPush(FlutterLocalNotificationsPlugin(), target.toData());
      active = [nativeShownNotification()];
      await installReadSession();
      calls.clear();
      await http.runWithClient(
        () =>
            showMatrixPush(FlutterLocalNotificationsPlugin(), target.toData()),
        () => MockClient(
          (request) async => http.Response(
            jsonEncode(
              request.url.path.endsWith('/sync')
                  ? serverRoomState(true)
                  : {'notifications': []},
            ),
            200,
          ),
        ),
      );
      expect(calls.where((call) => call.method == 'show'), isEmpty);
      expect(calls.where((call) => call.method == 'cancel'), hasLength(1));
      expect(
        await PushConversationStore().wasRead(target.userId, target.eventId),
        isFalse,
      );
    },
  );

  test(
    'server unmute clears a confirmed local mute and restores notifications',
    () async {
      await installReadSession();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(pushRoomMuteKey(target.userId, target.roomId), 1);
      await http.runWithClient(
        () =>
            showMatrixPush(FlutterLocalNotificationsPlugin(), target.toData()),
        () => MockClient(
          (request) async => http.Response(
            jsonEncode(
              request.url.path.endsWith('/sync')
                  ? serverRoomState(false)
                  : {'notifications': []},
            ),
            200,
          ),
        ),
      );
      expect(calls.where((call) => call.method == 'show'), hasLength(1));
      expect(
        prefs.containsKey(pushRoomMuteKey(target.userId, target.roomId)),
        isFalse,
      );
    },
  );

  test(
    'an old sync cannot undo a mute acknowledged while its query is pending',
    () async {
      await showMatrixPush(FlutterLocalNotificationsPlugin(), target.toData());
      active = [nativeShownNotification()];
      await installReadSession();
      calls.clear();
      final started = Completer<void>();
      final release = Completer<void>();
      final pending = http.runWithClient(
        () =>
            showMatrixPush(FlutterLocalNotificationsPlugin(), target.toData()),
        () => MockClient((request) async {
          if (request.url.path.endsWith('/sync')) {
            started.complete();
            await release.future;
            return http.Response(jsonEncode(serverRoomState(false)), 200);
          }
          return http.Response(jsonEncode({'notifications': []}), 200);
        }),
      );
      await started.future;
      await http.runWithClient(
        () => handleNotificationAction(action(muteActionId)),
        () => MockClient((request) async => http.Response('{}', 200)),
      );
      release.complete();
      await pending;
      expect(calls.where((call) => call.method == 'show'), isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.containsKey(pushRoomMuteKey(target.userId, target.roomId)),
        isTrue,
      );
    },
  );

  test('a delayed event read on another client is never posted', () async {
    await showMatrixPush(
      FlutterLocalNotificationsPlugin(),
      target.toData(),
      fetchReadEvents: (userId, ids) async {
        expect(userId, target.userId);
        expect(ids, contains(target.eventId));
        return {target.eventId};
      },
    );
    expect(calls.where((call) => call.method == 'show'), isEmpty);
    // A later offline retry still sees the persisted read confirmation.
    await showMatrixPush(
      FlutterLocalNotificationsPlugin(),
      target.toData(),
      fetchReadEvents: (userId, ids) async => {},
    );
    expect(calls.where((call) => call.method == 'show'), isEmpty);
  });

  test(
    'counts-only pushes withdraw read conversations in the background',
    () async {
      await showMatrixPush(FlutterLocalNotificationsPlugin(), target.toData());
      active = [nativeShownNotification()];
      calls.clear();
      await showMatrixPush(FlutterLocalNotificationsPlugin(), {
        'user_id': target.userId,
        'registration_id': 'current',
        'unread': '0',
      }, fetchReadEvents: (userId, ids) async => {target.eventId});
      expect(calls.where((call) => call.method == 'show'), isEmpty);
      expect(calls.where((call) => call.method == 'cancel'), hasLength(1));
      expect(
        await PushConversationStore().load(target.userId, target.roomId),
        isNull,
      );
    },
  );

  test(
    'counts-only pushes also withdraw native notifications without stored history',
    () async {
      await installReadSession();
      active = [
        {
          'id': 1,
          'tag': pushRoomTag(
            userId: target.userId,
            roomId: target.roomId,
            registrationId: 'current',
          ),
        },
      ];
      var requests = 0;
      await http.runWithClient(
        () => showMatrixPush(FlutterLocalNotificationsPlugin(), {
          'user_id': target.userId,
          'registration_id': 'current',
          'unread': '0',
        }),
        () => MockClient((request) async {
          requests++;
          expect(request.url.path, '/_matrix/client/v3/sync');
          return http.Response(
            jsonEncode({
              'rooms': {
                'join': {
                  target.roomId: {
                    'unread_notifications': {'notification_count': 0},
                  },
                },
              },
            }),
            200,
          );
        }),
      );
      expect(requests, 1);
      expect(calls.where((call) => call.method == 'cancel'), hasLength(1));
    },
  );

  test(
    'an empty sync boundary must not erase a genuinely unread message',
    () async {
      final notifications = FlutterLocalNotificationsPlugin();
      await showMatrixPush(notifications, target.toData());
      active = [nativeShownNotification()];
      await installReadSession();
      await http.runWithClient(
        () => dismissReadRoomPushes(
          target.userId,
          target.roomId,
          throughEventId: '',
        ),
        () => MockClient((request) async {
          if (request.url.path.endsWith('/sync')) {
            return http.Response(
              jsonEncode({
                'rooms': {
                  'join': {
                    target.roomId: {
                      'unread_notifications': {'notification_count': 1},
                    },
                  },
                },
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'notifications': [
                {
                  'event': {'event_id': target.eventId},
                  'read': false,
                },
              ],
            }),
            200,
          );
        }),
      );
      expect(calls.where((call) => call.method == 'cancel'), isEmpty);
      expect(
        await PushConversationStore().load(target.userId, target.roomId),
        isNotNull,
      );
    },
  );

  test(
    'a partial remote read removes old messages without dropping newer unread ones',
    () async {
      final notifications = FlutterLocalNotificationsPlugin();
      for (final event in [r'$old', r'$new']) {
        await showMatrixPush(notifications, {
          ...target.toData(),
          'event_id': event,
          'type': 'm.room.message',
          'content_body': event,
        });
      }
      active = [nativeShownNotification()];
      calls.clear();
      await showMatrixPush(
        notifications,
        {'user_id': target.userId, 'registration_id': 'current', 'unread': '0'},
        // The queued badge is stale: the server still has the newer unread event.
        fetchReadEvents: (userId, ids) async => {r'$old'},
      );
      expect(calls.where((call) => call.method == 'cancel'), isEmpty);
      final shows = calls.where((call) => call.method == 'show');
      expect(shows, hasLength(1));
      final specifics =
          (shows.single.arguments as Map)['platformSpecifics'] as Map;
      expect(specifics['onlyAlertOnce'], true);
      final style = specifics['styleInformation'] as Map;
      expect(
        (style['messages'] as List).map((entry) => (entry as Map)['text']),
        [r'$new'],
      );
      expect(
        (await PushConversationStore().load(
          target.userId,
          target.roomId,
        ))?.entries.map((entry) => entry.eventId),
        [r'$new'],
      );
    },
  );

  test(
    'a read completing during avatar resolution cannot resurrect the notification',
    () async {
      final resolving = Completer<void>();
      final release = Completer<void>();
      final push = showMatrixPush(
        FlutterLocalNotificationsPlugin(),
        target.toData(),
        publishShortcut: (id, title, path) async {
          resolving.complete();
          await release.future;
          return null;
        },
      );
      await resolving.future;
      await fcmPushRuntime.cancelRoomNotifications(
        target.userId,
        target.roomId,
        [target.eventId],
      );
      release.complete();
      await push;
      expect(calls.where((call) => call.method == 'show'), isEmpty);
    },
  );

  test(
    'a newer message in the same stable notification survives an in-flight read',
    () async {
      final notifications = FlutterLocalNotificationsPlugin();
      await showMatrixPush(notifications, target.toData());
      active = [nativeShownNotification()];
      api.pending = Completer<bool>();
      final read = markRoomAsReadWithPushCleanup(
        accountUserId: target.userId,
        roomId: target.roomId,
        explicit: true,
      );
      await pumpEventQueue();
      await showMatrixPush(notifications, {
        ...target.toData(),
        'event_id': r'$arriving',
        'type': 'm.room.message',
        'content_body': 'new',
      });
      active = [nativeShownNotification()];
      api.pending!.complete(true);
      await read;
      expect(calls.where((call) => call.method == 'cancel'), isEmpty);
      expect(
        (await PushConversationStore().load(
          target.userId,
          target.roomId,
        ))?.entries.map((entry) => entry.eventId),
        [r'$arriving'],
      );
      final specifics =
          (calls.lastWhere((call) => call.method == 'show').arguments
                  as Map)['platformSpecifics']
              as Map;
      final style = specifics['styleInformation'] as Map;
      expect(
        (style['messages'] as List).map((entry) => (entry as Map)['text']),
        ['new'],
      );
    },
  );

  test(
    'a push received before a receipt cannot surface after its pending read check',
    () async {
      final checking = Completer<void>();
      final release = Completer<Set<String>>();
      final push = showMatrixPush(
        FlutterLocalNotificationsPlugin(),
        target.toData(),
        fetchReadEvents: (userId, ids) {
          checking.complete();
          return release.future;
        },
      );
      await checking.future;
      await markRoomAsReadWithPushCleanup(
        accountUserId: target.userId,
        roomId: target.roomId,
        explicit: true,
      );
      release.complete({});
      await push;
      expect(calls.where((call) => call.method == 'show'), isEmpty);
    },
  );

  test(
    'push disabled during the server check prevents notification delivery',
    () async {
      await showMatrixPush(
        FlutterLocalNotificationsPlugin(),
        target.toData(),
        fetchReadEvents: (userId, ids) async {
          await PushSettingsStore().save(
            target.userId,
            const PushSettings(enabled: false, registrationId: 'current'),
          );
          return {};
        },
      );
      expect(calls.where((call) => call.method == 'show'), isEmpty);
    },
  );

  test(
    'a stale zero-unread snapshot preserves a newer queued message',
    () async {
      final notifications = FlutterLocalNotificationsPlugin();
      await showMatrixPush(notifications, target.toData());
      await showMatrixPush(notifications, {
        ...target.toData(),
        'event_id': r'$newer',
        'type': 'm.room.message',
        'content_body': 'newer',
      });
      active = [nativeShownNotification()];
      final room = rust.ChatRoom(
        id: target.roomId,
        name: 'Room',
        lastMessage: '',
        lastMessageTime: '0',
        lastEventId: target.eventId,
        unreadCount: 0,
        isMarkedUnread: false,
        roomType: 'dm',
        isEncrypted: false,
        isMuted: false,
        roomState: 'joined',
      );
      final container = ProviderContainer(
        overrides: [
          allChatRoomsProvider.overrideWith((ref) async => [room]),
        ],
      );
      addTearDown(container.dispose);
      container.read(sessionReadyProvider.notifier).value = true;
      container.read(activeUserIdProvider.notifier).value = target.userId;
      container.listen(pushReadStateProvider, (_, _) {}, fireImmediately: true);
      await container.read(allChatRoomsProvider.future);
      await pumpEventQueue();
      expect(calls.where((call) => call.method == 'cancel'), isEmpty);
      expect(
        (await PushConversationStore().load(
          target.userId,
          target.roomId,
        ))?.entries.map((entry) => entry.eventId),
        [r'$newer'],
      );
    },
  );

  test(
    'the first synced snapshot can already be read on another device',
    () async {
      await showMatrixPush(FlutterLocalNotificationsPlugin(), target.toData());
      active = [nativeShownNotification()];
      final room = rust.ChatRoom(
        id: target.roomId,
        name: 'Room',
        lastMessage: '',
        lastMessageTime: '0',
        lastEventId: target.eventId,
        unreadCount: 0,
        isMarkedUnread: false,
        roomType: 'dm',
        isEncrypted: false,
        isMuted: false,
        roomState: 'joined',
      );
      final container = ProviderContainer(
        overrides: [
          allChatRoomsProvider.overrideWith((ref) async => [room]),
        ],
      );
      addTearDown(container.dispose);
      container.read(sessionReadyProvider.notifier).value = true;
      container.read(activeUserIdProvider.notifier).value = target.userId;
      container.listen(pushReadStateProvider, (_, _) {}, fireImmediately: true);
      await container.read(allChatRoomsProvider.future);
      await pumpEventQueue();
      expect(calls.where((call) => call.method == 'cancel'), hasLength(1));
      final queries = calls
          .where((call) => call.method == 'getActiveNotifications')
          .length;
      container.invalidate(allChatRoomsProvider);
      await container.read(allChatRoomsProvider.future);
      await pumpEventQueue();
      expect(
        calls.where((call) => call.method == 'getActiveNotifications'),
        hasLength(queries),
      );
    },
  );

  test(
    'rebuilding legacy encrypted history must not enable a plaintext reply',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        pushConversationsKey(target.userId),
        jsonEncode({
          target.roomId: {
            'entries': [
              for (final id in [target.eventId, r'$unread'])
                {
                  'sender_id': '@bob:example.org', 'sender_name': 'Bob',
                  'body': '已加密的新消息', 'event_id': id, 'received_at': 1,
                  // Versions before this fix did not store the event type.
                },
            ],
            'latest_event_id': r'$unread',
            'updated_at': 1,
          },
        }),
      );
      active = [
        {
          'id': 1,
          'tag': pushRoomTag(
            userId: target.userId,
            roomId: target.roomId,
            registrationId: 'current',
          ),
        },
      ];
      await fcmPushRuntime.cancelRoomNotifications(
        target.userId,
        target.roomId,
        [target.eventId],
      );
      final specifics =
          (calls.lastWhere((call) => call.method == 'show').arguments
                  as Map)['platformSpecifics']
              as Map;
      expect(
        (specifics['actions'] as List).map((action) => (action as Map)['id']),
        [markReadActionId, muteActionId],
      );
      final style = specifics['styleInformation'] as Map;
      expect(
        (style['messages'] as List).map((entry) => (entry as Map)['text']),
        ['已加密的新消息'],
      );
    },
  );

  test('stable room tags still identify active notifications', () async {
    await showMatrixPush(FlutterLocalNotificationsPlugin(), target.toData());
    final shown = calls.last.arguments as Map;
    final specifics = shown['platformSpecifics'] as Map;
    // Android's active-notification API does not return the Flutter payload.
    active = [
      {'id': shown['id'], 'tag': specifics['tag']},
    ];
    expect(
      await fcmPushRuntime.roomNotificationEvents(target.userId, target.roomId),
      [target.eventId],
    );
    await dismissReadRoomPushes(target.userId, target.roomId);
    expect(calls.where((call) => call.method == 'cancel'), hasLength(1));
    expect(
      await PushConversationStore().load(target.userId, target.roomId),
      isNull,
    );
  });

  test(
    'read cleanup clears history after the notification was swiped away',
    () async {
      await showMatrixPush(FlutterLocalNotificationsPlugin(), target.toData());
      active = [];
      await markRoomAsReadWithPushCleanup(
        accountUserId: target.userId,
        roomId: target.roomId,
        explicit: true,
      );
      expect(
        await PushConversationStore().load(target.userId, target.roomId),
        isNull,
      );
      calls.clear();
      await showMatrixPush(FlutterLocalNotificationsPlugin(), target.toData());
      expect(calls.where((call) => call.method == 'show'), isEmpty);
    },
  );

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
    await fcmPushRuntime.cancelRoomNotifications(target.userId, target.roomId, [
      target.eventId,
    ]);
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
        expect(args['body'], switch (type) {
          'm.room.message' || 'm.sticker' => 'Sygnal 消息正文',
          'm.room.encrypted' => '已加密的消息',
          _ => '你有一条新消息',
        });
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
