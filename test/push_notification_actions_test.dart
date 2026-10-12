import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matter/features/push/push_avatar.dart';
import 'package:matter/features/push/push_notification_actions.dart';
import 'package:matter/features/push/push_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const target = PushTarget(
    userId: '@alice:example.org',
    roomId: '!room:example.org',
    eventId: r'$event',
    registrationId: 'current',
  );
  const session = PushMediaSession(
    homeserver: 'https://matrix.example.org',
    accessToken: 'token',
  );
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'read action sends the owning account receipt and clears its unread mark',
    () async {
      var requests = 0;
      final client = MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer token');
        expect(request.url.host, 'matrix.example.org');
        if (++requests == 1) {
          expect(request.method, 'POST');
          expect(request.url.pathSegments, [
            '_matrix',
            'client',
            'v3',
            'rooms',
            target.roomId,
            'receipt',
            'm.read',
            target.eventId,
          ]);
          expect(jsonDecode(request.body), {});
        } else {
          expect(request.method, 'PUT');
          expect(request.url.pathSegments, [
            '_matrix',
            'client',
            'v3',
            'user',
            target.userId,
            'rooms',
            target.roomId,
            'account_data',
            'm.marked_unread',
          ]);
          expect(jsonDecode(request.body), {'unread': false});
        }
        return http.Response('{}', 200);
      });
      expect(
        await performNotificationRoomAction(
          target: target,
          mute: false,
          session: session,
          client: client,
        ),
        isTrue,
      );
      expect(requests, 2);
    },
  );

  test(
    'mute uses a room override above mentions and enables a disabled rule',
    () async {
      var requests = 0;
      final client = MockClient((request) async {
        expect(request.method, 'PUT');
        expect(request.headers['Authorization'], 'Bearer token');
        final segments = request.url.pathSegments;
        expect(segments.take(6), [
          '_matrix',
          'client',
          'v3',
          'pushrules',
          'global',
          'override',
        ]);
        expect(segments[6], target.roomId);
        if (++requests == 1) {
          expect(jsonDecode(request.body), {
            'actions': [],
            'conditions': [
              {
                'kind': 'event_match',
                'key': 'room_id',
                'pattern': target.roomId,
              },
            ],
          });
        } else {
          expect(segments.last, 'enabled');
          expect(jsonDecode(request.body), {'enabled': true});
        }
        return http.Response('{}', 200);
      });
      expect(
        await performNotificationRoomAction(
          target: target,
          mute: true,
          session: session,
          client: client,
        ),
        isTrue,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getInt(pushRoomMuteKey(target.userId, target.roomId)),
        isNotNull,
      );
      expect(
        prefs.containsKey(pushRoomMuteKey('@bob:example.org', target.roomId)),
        isFalse,
      );
    },
  );

  test('transport failures cannot report an acknowledged action', () async {
    for (final mute in [true, false]) {
      expect(
        await performNotificationRoomAction(
          target: target,
          mute: mute,
          session: session,
          client: MockClient(
            (request) async => throw http.ClientException('offline'),
          ),
        ),
        isFalse,
      );
    }
  });
}
