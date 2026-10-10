import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matter/features/push/push_avatar.dart';
import 'package:matter/features/push/push_reply.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records requests and replies with a canned response.
class _RecordingClient extends http.BaseClient {
  _RecordingClient({this.statusCode = 200, this.throwOnSend = false});

  final int statusCode;
  final bool throwOnSend;
  final List<http.BaseRequest> requests = [];
  final List<String> bodies = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    if (request is http.Request) bodies.add(request.body);
    if (throwOnSend) throw const SocketExceptionStub();
    return http.StreamedResponse(const Stream.empty(), statusCode);
  }
}

class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const alice = '@alice:example.org';
  const room = '!room:example.org';
  const session = PushMediaSession(
    homeserver: 'https://matrix.example.org',
    accessToken: 'token',
  );

  group('mxcThumbnailUrl', () {
    test('maps an mxc URI to the authenticated media endpoint', () {
      expect(
        mxcThumbnailUrl('mxc://matrix.example.org/abc123', homeserver: 'https://matrix.example.org'),
        'https://matrix.example.org/_matrix/client/v1/media/thumbnail/'
        'matrix.example.org/abc123?width=96&height=96&method=scale',
      );
    });

    test('keeps a non-default media port, matching the Rust resolver', () {
      expect(
        mxcThumbnailUrl(
          'mxc://media.example.org:8448/abc',
          homeserver: 'https://matrix.example.org',
        ),
        contains('media.example.org:8448/abc'),
      );
    });

    test('tolerates a trailing slash on the homeserver', () {
      expect(
        mxcThumbnailUrl(
          'mxc://matrix.example.org/abc',
          homeserver: 'https://matrix.example.org///',
        ),
        startsWith('https://matrix.example.org/_matrix/'),
      );
    });

    test('rejects non-mxc input and missing identifiers', () {
      for (final mxc in [
        'https://example.org/avatar.png',
        'mxc://',
        'mxc://matrix.example.org',
        'not a uri',
      ]) {
        expect(
          mxcThumbnailUrl(mxc, homeserver: 'https://matrix.example.org'),
          isNull,
          reason: mxc,
        );
      }
      expect(
        mxcThumbnailUrl('mxc://matrix.example.org/a', homeserver: '   '),
        isNull,
      );
    });
  });

  group('PushAvatarStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('round-trips bytes and isolates accounts', () async {
      final store = PushAvatarStore();
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      await store.save(alice, 'mxc://a/b', bytes);
      expect(await PushAvatarStore().cached(alice, 'mxc://a/b'), bytes);
      const bob = '@bob:example.org';
      expect(await store.cached(bob, 'mxc://a/b'), isNull);
    });

    test('returns null for unknown and corrupt entries', () async {
      SharedPreferences.setMockInitialValues({
        pushAvatarCacheKey(alice): 'not json',
      });
      expect(await PushAvatarStore().cached(alice, 'mxc://a/b'), isNull);
    });

    test('bounds the cache instead of growing without limit', () async {
      final store = PushAvatarStore();
      for (var i = 0; i < 80; i++) {
        await store.save(alice, 'mxc://example.org/$i', Uint8List.fromList([i]));
      }
      final raw = jsonDecode(
        (await SharedPreferences.getInstance()).getString(
          pushAvatarCacheKey(alice),
        )!,
      ) as Map<String, dynamic>;
      expect(raw.length, lessThanOrEqualTo(64));
      // The most recent entry is retained.
      expect(raw.containsKey('mxc://example.org/79'), isTrue);
    });

    test('clearing an account drops only its avatars', () async {
      final store = PushAvatarStore();
      const bob = '@bob:example.org';
      await store.save(alice, 'mxc://a/b', Uint8List.fromList([1]));
      await store.save(bob, 'mxc://a/b', Uint8List.fromList([2]));
      await store.clearAccount(alice);
      expect(await store.cached(alice, 'mxc://a/b'), isNull);
      expect(await store.cached(bob, 'mxc://a/b'), isNotNull);
    });

    test('a fetch failure never blocks the notification', () async {
      final store = PushAvatarStore();
      final bytes = await loadAvatarBytes(
        store: store,
        userId: alice,
        mxc: 'not-an-mxc',
        session: session,
      );
      expect(bytes, isNull);
    });

    test('serves from cache without needing a session', () async {
      final store = PushAvatarStore();
      await store.save(alice, 'mxc://a/b', Uint8List.fromList([9]));
      expect(
        await loadAvatarBytes(
          store: store,
          userId: alice,
          mxc: 'mxc://a/b',
          session: null,
        ),
        Uint8List.fromList([9]),
      );
    });
  });

  group('sendNotificationReply', () {
    test('PUTs the text to the room send endpoint with an auth header', () async {
      final client = _RecordingClient();
      final sent = await sendNotificationReply(
        userId: alice,
        roomId: room,
        body: '  在的  ',
        session: session,
        client: client,
      );
      expect(sent, isTrue);
      final request = client.requests.single as http.Request;
      expect(request.method, 'PUT');
      expect(
        request.url.path,
        startsWith('/_matrix/client/v3/rooms/'),
      );
      expect(request.url.path, contains('/send/m.room.message/'));
      expect(request.headers['Authorization'], 'Bearer token');
      // The typed text is trimmed before sending.
      expect(jsonDecode(client.bodies.single), {
        'msgtype': 'm.text',
        'body': '在的',
      });
    });

    test('encodes the room id into the path', () async {
      final client = _RecordingClient();
      await sendNotificationReply(
        userId: alice,
        roomId: room,
        body: 'hi',
        session: session,
        client: client,
      );
      expect(client.requests.single.url.path, contains(Uri.encodeComponent(room)));
    });

    test('uses a fresh idempotency key per reply so retries cannot double-send', () {
      final ids = {for (var i = 0; i < 50; i++) newReplyTransactionId()};
      expect(ids, hasLength(50));
    });

    test('rejects blank text and a non-room id without any request', () async {
      final client = _RecordingClient();
      for (final (roomId, body) in [
        (room, '   '),
        (room, ''),
        ('not-a-room', 'hi'),
      ]) {
        expect(
          await sendNotificationReply(
            userId: alice,
            roomId: roomId,
            body: body,
            session: session,
            client: client,
          ),
          isFalse,
          reason: '$roomId/$body',
        );
      }
      expect(client.requests, isEmpty);
    });

    test('reports failure on a non-2xx response and on a transport error', () async {
      expect(
        await sendNotificationReply(
          userId: alice,
          roomId: room,
          body: 'hi',
          session: session,
          client: _RecordingClient(statusCode: 403),
        ),
        isFalse,
      );
      expect(
        await sendNotificationReply(
          userId: alice,
          roomId: room,
          body: 'hi',
          session: session,
          client: _RecordingClient(throwOnSend: true),
        ),
        isFalse,
      );
    });

    test('without a session there is nothing to send with', () async {
      expect(
        await sendNotificationReply(
          userId: '@nobody:example.org',
          roomId: room,
          body: 'hi',
          client: _RecordingClient(),
        ),
        isFalse,
      );
    });
  });
}
