import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matter/features/push/push_avatar.dart';
import 'package:matter/features/push/push_read_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const user = '@alice:example.org';
  const session = PushMediaSession(
    homeserver: 'https://matrix.example.org',
    accessToken: 'test-token',
  );
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Map<String, dynamic> notification(String id, Object? read) => {
    'event': {'event_id': id},
    'read': read,
  };

  test('only valid scoped room counts are reported', () async {
    final counts = <String, int>{};
    await fetchReadPushEvents(
      user,
      {},
      session: session,
      roomIds: {
        '!full:example.org',
        '!fallback:example.org',
        '!bad:example.org',
        '!missing:example.org',
      },
      onRoomUnreadCount: (id, count) => counts[id] = count,
      client: MockClient(
        (request) async => http.Response(
          jsonEncode({
            'rooms': {
              'join': {
                '!full:example.org': {
                  'org.matrix.msc2654.unread_count': 120,
                  'unread_notifications': {'notification_count': 5},
                },
                '!fallback:example.org': {
                  'org.matrix.msc2654.unread_count': -1,
                  'unread_notifications': {'notification_count': 9},
                },
                '!bad:example.org': {
                  'unread_notifications': {'notification_count': '7'},
                },
                '!missing:example.org': {},
                '!other:example.org': {
                  'unread_notifications': {'notification_count': 99},
                },
              },
            },
          }),
          200,
        ),
      ),
    );
    expect(counts, {'!full:example.org': 120, '!fallback:example.org': 9});
  });

  test(
    'mute status requires a valid rule list and an enabled whole-room override',
    () async {
      for (final overrides in [
        <Map<String, dynamic>>[],
        [
          {
            'enabled': true,
            'actions': [],
            'conditions': [
              {
                'kind': 'event_match',
                'key': 'room_id',
                'pattern': '!room:example.org',
              },
            ],
          },
        ],
        [
          {
            'enabled': false,
            'actions': [],
            'conditions': [
              {
                'kind': 'event_match',
                'key': 'room_id',
                'pattern': '!room:example.org',
              },
            ],
          },
        ],
      ]) {
        final states = <String, bool>{};
        await fetchReadPushEvents(
          user,
          {},
          session: session,
          roomIds: {'!room:example.org', '!other:example.org'},
          onRoomMuted: (id, muted) => states[id] = muted,
          client: MockClient(
            (request) async => http.Response(
              jsonEncode({
                'account_data': {
                  'events': [
                    {
                      'type': 'm.push_rules',
                      'content': {
                        'global': {'override': overrides},
                      },
                    },
                  ],
                },
              }),
              200,
            ),
          ),
        );
        expect(
          states['!room:example.org'],
          overrides.isNotEmpty && overrides.first['enabled'] == true,
        );
        expect(states['!other:example.org'], isFalse);
      }
      final states = <String, bool>{};
      await fetchReadPushEvents(
        user,
        {},
        session: session,
        roomIds: {'!room:example.org'},
        onRoomMuted: (id, muted) => states[id] = muted,
        client: MockClient((request) async => http.Response('{}', 200)),
      );
      expect(states, isEmpty);
    },
  );

  test(
    'only confirmed read events from the requested account are returned',
    () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/_matrix/client/v3/notifications');
        expect(request.url.queryParameters['limit'], '100');
        expect(request.headers['Authorization'], 'Bearer test-token');
        return http.Response(
          jsonEncode({
            'notifications': [
              notification(r'$read', true),
              notification(r'$unread', false),
              notification(r'$unknown', null),
              notification(r'$other', true),
            ],
          }),
          200,
        );
      });
      expect(
        await fetchReadPushEvents(
          user,
          {r'$read', r'$unread', r'$unknown'},
          session: session,
          client: client,
        ),
        {r'$read'},
      );
    },
  );

  test(
    'pagination finds delayed events without treating absent events as read',
    () async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        if (requests == 1) {
          expect(request.url.queryParameters['from'], isNull);
          return http.Response(
            jsonEncode({
              'notifications': [notification(r'$new', false)],
              'next_token': 'next page',
            }),
            200,
          );
        }
        expect(request.url.queryParameters['from'], 'next page');
        return http.Response(
          jsonEncode({
            'notifications': [notification(r'$old', true)],
          }),
          200,
        );
      });
      expect(
        await fetchReadPushEvents(
          user,
          {r'$old', r'$new', r'$absent'},
          session: session,
          client: client,
        ),
        {r'$old'},
      );
      expect(requests, 2);
    },
  );

  test(
    'authentication and transport failures do not invent read confirmations',
    () async {
      for (final client in [
        MockClient((request) async => http.Response('{}', 401)),
        MockClient((request) async => throw http.ClientException('offline')),
      ]) {
        expect(
          await fetchReadPushEvents(
            user,
            {r'$event'},
            session: session,
            client: client,
          ),
          isEmpty,
        );
      }
    },
  );

  test(
    'a later malformed page retains confirmations already received',
    () async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        if (requests == 1) {
          return http.Response(
            jsonEncode({
              'notifications': [notification(r'$read', true)],
              'next_token': 'older',
            }),
            200,
          );
        }
        return http.Response('not JSON', 200);
      });
      expect(
        await fetchReadPushEvents(
          user,
          {r'$read', r'$unknown'},
          session: session,
          client: client,
        ),
        {r'$read'},
      );
    },
  );

  test('a busy account cannot cause unbounded background pagination', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return http.Response(
        jsonEncode({
          'notifications': [notification('\$unrelated$requests', false)],
          'next_token': 'page-$requests',
        }),
        200,
      );
    });
    expect(
      await fetchReadPushEvents(
        user,
        {r'$absent'},
        session: session,
        client: client,
      ),
      isEmpty,
    );
    expect(requests, 3);
  });

  test(
    'fresh zero-unread rooms cover old events beyond notification pages',
    () async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        expect(request.url.path, '/_matrix/client/v3/sync');
        expect(request.url.queryParameters['timeout'], '0');
        final filter =
            jsonDecode(request.url.queryParameters['filter']!) as Map;
        expect((filter['room'] as Map)['rooms'], ['!read:example.org']);
        expect((filter['room'] as Map)['timeline'], {'limit': 0});
        return http.Response(
          jsonEncode({
            'rooms': {
              'join': {
                '!read:example.org': {
                  'unread_notifications': {'notification_count': 0},
                },
              },
            },
          }),
          200,
        );
      });
      expect(
        await fetchReadPushEvents(
          user,
          {r'$old', r'$older'},
          session: session,
          client: client,
          roomByEvent: {
            r'$old': '!read:example.org',
            r'$older': '!read:example.org',
            r'$notRequested': '!read:example.org',
          },
        ),
        {r'$old', r'$older'},
      );
      expect(requests, 1);
    },
  );

  test(
    'read flags trim part of a room while fresh unread counts preserve new messages',
    () async {
      final paths = <String>[];
      final client = MockClient((request) async {
        paths.add(request.url.path);
        if (request.url.path.endsWith('/sync')) {
          return http.Response(
            jsonEncode({
              'rooms': {
                'join': {
                  '!read:example.org': {
                    'unread_notifications': {'notification_count': 0},
                  },
                  '!unread:example.org': {
                    'unread_notifications': {'notification_count': 2},
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
              notification(r'$privateRead', true),
              notification(r'$new', false),
            ],
          }),
          200,
        );
      });
      expect(
        await fetchReadPushEvents(
          user,
          {r'$old', r'$privateRead', r'$new'},
          session: session,
          client: client,
          roomByEvent: {
            r'$old': '!read:example.org',
            r'$privateRead': '!unread:example.org',
            r'$new': '!unread:example.org',
          },
        ),
        {r'$old', r'$privateRead'},
      );
      expect(paths, [
        '/_matrix/client/v3/sync',
        '/_matrix/client/v3/notifications',
      ]);
    },
  );

  test(
    'a failed room sync still checks individual notification read flags',
    () async {
      for (final throws in [false, true]) {
        final client = MockClient((request) async {
          if (request.url.path.endsWith('/sync')) {
            if (throws) throw http.ClientException('sync unavailable');
            return http.Response('{}', 503);
          }
          return http.Response(
            jsonEncode({
              'notifications': [notification(r'$read', true)],
            }),
            200,
          );
        });
        expect(
          await fetchReadPushEvents(
            user,
            {r'$read'},
            session: session,
            client: client,
            roomByEvent: {r'$read': '!room:example.org'},
          ),
          {r'$read'},
        );
      }
    },
  );

  test(
    'an omitted notification count never implies that a room is read',
    () async {
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/sync')) {
          return http.Response(
            jsonEncode({
              'rooms': {
                'join': {
                  '!room:example.org': {
                    'unread_notifications': {'highlight_count': 0},
                  },
                },
              },
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'notifications': [notification(r'$new', false)],
          }),
          200,
        );
      });
      expect(
        await fetchReadPushEvents(
          user,
          {r'$new'},
          session: session,
          client: client,
          roomByEvent: {r'$new': '!room:example.org'},
        ),
        isEmpty,
      );
    },
  );

  test('an empty query or missing session makes no network request', () async {
    final client = MockClient(
      (request) async => throw StateError('unexpected request'),
    );
    expect(
      await fetchReadPushEvents(user, {}, session: session, client: client),
      isEmpty,
    );
    expect(
      await fetchReadPushEvents(user, {r'$event'}, client: client),
      isEmpty,
    );
  });
}
