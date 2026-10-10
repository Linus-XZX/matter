import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matter/features/push/push_avatar.dart';
import 'package:matter/features/push/push_reply.dart';
import 'package:matter/features/push/push_room_directory.dart';
import 'package:matter/providers/session_credential_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'support/temp_path_provider.dart';

/// Models a native preference read whose reply arrives after other file IO.
class _DelayedPreferencesStore extends SharedPreferencesStorePlatform {
  _DelayedPreferencesStore(this.inner);
  final SharedPreferencesStorePlatform inner;

  @override
  Future<Map<String, Object>> getAll() async {
    final values = await inner.getAll();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return values;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) =>
      inner.setValue(valueType, key, value);
  @override
  Future<bool> remove(String key) => inner.remove(key);
  @override
  Future<bool> clear() => inner.clear();
}

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
  const bob = '@bob:example.org';
  const room = '!room:example.org';
  const session = PushMediaSession(
    homeserver: 'https://matrix.example.org',
    accessToken: 'token',
  );

  late Directory root;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('matter-avatars');
    installTempPathProvider(root);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('PushAvatarCache', () {
    // Counts downloads so the cache-first path is observable.
    late int downloads;
    late PushAvatarCache cache;

    setUp(() {
      downloads = 0;
      cache = PushAvatarCache(
        download: (mxc) async {
          downloads++;
          return Uint8List.fromList([1, 2, 3]);
        },
      );
    });

    test('writes the avatar to a file and returns its path', () async {
      final path = await cache.ensure(alice, 'mxc://example.org/avatar');
      expect(path, isNotNull);
      expect(File(path!).existsSync(), isTrue);
      expect(File(path).readAsBytesSync(), [1, 2, 3]);
    });

    test(
      'a second lookup is served from disk without downloading again',
      () async {
        final first = await cache.ensure(alice, 'mxc://example.org/avatar');
        final second = await cache.ensure(alice, 'mxc://example.org/avatar');
        expect(second, first);
        expect(downloads, 1);
      },
    );

    test('the recorded path is readable without any download', () async {
      final written = await cache.ensure(alice, 'mxc://example.org/avatar');
      // This is the only lookup the notification path performs.
      expect(await pushAvatarPath(alice, 'mxc://example.org/avatar'), written);
    });

    test('keeps accounts separate', () async {
      await cache.ensure(alice, 'mxc://example.org/avatar');
      expect(await pushAvatarPath(bob, 'mxc://example.org/avatar'), isNull);
    });

    test('a failed download yields no path instead of failing', () async {
      final failing = PushAvatarCache(download: (mxc) async => null);
      expect(await failing.ensure(alice, 'mxc://example.org/avatar'), isNull);
      // Non-mxc input never reaches the downloader.
      expect(await failing.ensure(alice, 'https://example.org/a.png'), isNull);
    });

    test('concurrent requests for one avatar download it once', () async {
      // The prefetch runs on sync updates, so two overlapping runs can ask for
      // the same avatar before either has written it.
      final gate = Completer<void>();
      var calls = 0;
      final slow = PushAvatarCache(
        download: (mxc) async {
          calls++;
          await gate.future;
          return Uint8List.fromList([7]);
        },
      );
      final first = slow.ensure(alice, 'mxc://example.org/avatar');
      final second = slow.ensure(alice, 'mxc://example.org/avatar');
      gate.complete();
      final paths = await Future.wait([first, second]);
      expect(calls, 1);
      expect(paths.first, paths.last);
      // A later request is served from disk without downloading again.
      expect(await slow.ensure(alice, 'mxc://example.org/avatar'), paths.first);
      expect(calls, 1);
    });

    test('a stale file path is not handed to Android', () async {
      final path = await cache.ensure(alice, 'mxc://example.org/avatar');
      File(path!).deleteSync();
      // Decoding a missing file shows no icon and logs an error, so the
      // lookup must report the cache as cold.
      expect(await pushAvatarPath(alice, 'mxc://example.org/avatar'), isNull);
    });

    test('recovers from a corrupt index', () async {
      SharedPreferences.setMockInitialValues({
        pushAvatarIndexKey(alice): 'not json',
      });
      expect(await pushAvatarPath(alice, 'mxc://example.org/avatar'), isNull);
      expect(await cache.ensure(alice, 'mxc://example.org/avatar'), isNotNull);
    });

    test('bounds the cache and deletes the evicted files', () async {
      String? firstPath;
      for (var i = 0; i < 140; i++) {
        final path = await cache.ensure(alice, 'mxc://example.org/$i');
        firstPath ??= path;
      }
      expect(File(firstPath!).existsSync(), isFalse);
      // The newest entry survives.
      expect(await pushAvatarPath(alice, 'mxc://example.org/139'), isNotNull);
    });

    test('sender prefetch cannot evict joined-room avatars', () async {
      await savePushRoomDirectory(alice, [
        (
          id: room,
          name: 'Room',
          roomType: 'group',
          avatarMxc: 'mxc://example.org/room',
          isEncrypted: false,
        ),
      ]);
      final roomPath = await cache.ensure(alice, 'mxc://example.org/room');
      for (var i = 0; i < 140; i++) {
        await cache.ensure(alice, 'mxc://example.org/sender$i');
      }
      expect(await pushAvatarPath(alice, 'mxc://example.org/room'), roomPath);
      expect(File(roomPath!).existsSync(), isTrue);
    });

    test('concurrent different avatars retain every index entry', () async {
      final original = SharedPreferencesStorePlatform.instance;
      SharedPreferencesStorePlatform.instance = _DelayedPreferencesStore(
        original,
      );
      addTearDown(() => SharedPreferencesStorePlatform.instance = original);
      final mxcs = [for (var i = 0; i < 20; i++) 'mxc://example.org/person$i'];
      final paths = await Future.wait([
        for (final mxc in mxcs) cache.ensure(alice, mxc),
      ]);
      for (var i = 0; i < mxcs.length; i++) {
        expect(await pushAvatarPath(alice, mxcs[i]), paths[i], reason: mxcs[i]);
      }
    });

    test('clearing an account deletes its files and leaves others', () async {
      final alicePath = await cache.ensure(alice, 'mxc://example.org/avatar');
      await cache.ensure(bob, 'mxc://example.org/avatar');
      await cache.clearAccount(alice);
      expect(File(alicePath!).existsSync(), isFalse);
      expect(await pushAvatarPath(alice, 'mxc://example.org/avatar'), isNull);
      expect(await pushAvatarPath(bob, 'mxc://example.org/avatar'), isNotNull);
    });
  });

  test(
    'background read checks use the configured compatibility credentials',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await enableSessionCredentialCompatibilityMode();
      await storeSessionCredentials(
        userId: alice,
        accessToken: 'compat-token',
        writeSecureCredentials: () async =>
            fail('compatibility mode must not write to Keystore'),
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'multi_sessions',
        jsonEncode([
          {'user_id': alice, 'homeserver_url': session.homeserver},
        ]),
      );
      final loaded = await loadPushMediaSession(alice);
      expect(loaded?.homeserver, session.homeserver);
      expect(loaded?.accessToken, 'compat-token');
    },
  );

  group('sendNotificationReply', () {
    test(
      'PUTs the text to the room send endpoint with an auth header',
      () async {
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
        expect(request.url.path, startsWith('/_matrix/client/v3/rooms/'));
        expect(request.url.path, contains('/send/m.room.message/'));
        expect(request.headers['Authorization'], 'Bearer token');
        // The typed text is trimmed before sending.
        expect(jsonDecode(client.bodies.single), {
          'msgtype': 'm.text',
          'body': '在的',
        });
      },
    );

    test('encodes the room id into the path', () async {
      final client = _RecordingClient();
      await sendNotificationReply(
        userId: alice,
        roomId: room,
        body: 'hi',
        session: session,
        client: client,
      );
      expect(
        client.requests.single.url.path,
        contains(Uri.encodeComponent(room)),
      );
    });

    test(
      'uses a fresh idempotency key per reply so retries cannot double-send',
      () {
        final ids = {for (var i = 0; i < 50; i++) newReplyTransactionId()};
        expect(ids, hasLength(50));
      },
    );

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

    test(
      'reports failure on a non-2xx response and on a transport error',
      () async {
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
      },
    );

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
