import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:matter/providers/auth_provider.dart';
import 'package:matter/features/markdown/markdown_source_store.dart';
import 'package:matter/src/rust/frb_generated.dart';

class _FakeRustApi implements RustLibApi {
  final sdkCleanupCalls = <({String userId, String dataDir})>[];

  @override
  Future<void> crateApiMatrixCleanupRemovedAccountStore({
    required String userId,
    required String dataDir,
  }) async {
    sdkCleanupCalls.add((userId: userId, dataDir: dataDir));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
  }
}

String _removedSessionTestKey(String userId) =>
    'matrix_session_removed_${base64Url.encode(utf8.encode(userId))}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late _FakeRustApi rustApi;

  setUpAll(() {
    rustApi = _FakeRustApi();
    RustLib.initMock(api: rustApi);
  });

  tearDownAll(RustLib.dispose);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          switch (call.method) {
            case 'getTemporaryDirectory':
            case 'getApplicationSupportDirectory':
              return '/tmp/matter_auth_provider_test';
          }
          return null;
        });
    rustApi.sdkCleanupCalls.clear();
  });

  group('active user id persistence', () {
    test('saveActiveUserId writes the active user key', () async {
      await saveActiveUserId('@alice:example.org');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('active_user_id'), '@alice:example.org');
    });

    test('loadActiveUserId reads the persisted value', () async {
      SharedPreferences.setMockInitialValues({
        'active_user_id': '@bob:example.org',
      });
      expect(await loadActiveUserId(), '@bob:example.org');
    });

    test('loadActiveUserId returns null when unset', () async {
      expect(await loadActiveUserId(), isNull);
    });
  });

  group('display name persistence', () {
    test('loadDisplayName returns the stored name', () async {
      SharedPreferences.setMockInitialValues({
        'session_display_names': jsonEncode({'@alice:example.org': 'Alice'}),
      });
      expect(await loadDisplayName('@alice:example.org'), 'Alice');
    });

    test('loadDisplayName falls back to localpart', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await loadDisplayName('@bob:example.org'), 'bob');
    });
  });

  group('session persistence', () {
    test('addSession stores metadata and secure token', () async {
      await addSession(
        homeserver: 'https://example.org',
        accessToken: 'token-a',
        refreshToken: 'refresh-a',
        userId: '@alice:example.org',
        deviceId: 'DEVICE_A',
        displayName: 'Alice',
      );

      final prefs = await SharedPreferences.getInstance();
      final sessionsRaw = prefs.getString('multi_sessions');
      expect(sessionsRaw, isNotNull);

      final sessions = jsonDecode(sessionsRaw!) as List;
      expect(sessions.length, 1);
      expect(sessions.first['user_id'], '@alice:example.org');
      expect(sessions.first['homeserver_url'], 'https://example.org');
      expect(sessions.first['device_id'], 'DEVICE_A');
      expect(sessions.first.containsKey('access_token'), isFalse);

      expect(prefs.getString('active_user_id'), '@alice:example.org');
      final names = jsonDecode(prefs.getString('session_display_names')!);
      expect(names['@alice:example.org'], 'Alice');

      final secure = FlutterSecureStorage();
      final token = await secure.read(
        key:
            'matrix_access_token_${base64Url.encode(utf8.encode('@alice:example.org'))}',
      );
      expect(token, 'token-a');
      final refreshToken = await secure.read(
        key:
            'matrix_refresh_token_${base64Url.encode(utf8.encode('@alice:example.org'))}',
      );
      expect(refreshToken, 'refresh-a');
    });

    test(
      'loadAllSessions restores sessions from metadata and secure storage',
      () async {
        await addSession(
          homeserver: 'https://example.org',
          accessToken: 'token-a',
          userId: '@alice:example.org',
          deviceId: 'DEVICE_A',
          displayName: 'Alice',
        );
        await addSession(
          homeserver: 'https://matrix.org',
          accessToken: 'token-b',
          userId: '@bob:matrix.org',
          deviceId: 'DEVICE_B',
          displayName: 'Bob',
        );

        final sessions = await loadAllSessions();
        expect(sessions.map((s) => s.userId), [
          '@alice:example.org',
          '@bob:matrix.org',
        ]);
        expect(sessions.map((s) => s.accessToken), ['token-a', 'token-b']);
      },
    );

    test(
      'loadAllSessions restores refresh tokens from secure storage',
      () async {
        await addSession(
          homeserver: 'https://example.org',
          accessToken: 'token-a',
          refreshToken: 'refresh-a',
          userId: '@alice:example.org',
          deviceId: 'DEVICE_A',
          displayName: 'Alice',
        );

        final sessions = await loadAllSessions();
        expect(sessions.single.refreshToken, 'refresh-a');
      },
    );

    test('startup finishes cleanup for a marked removal', () async {
      await addSession(
        homeserver: 'https://example.org',
        accessToken: 'token-a',
        refreshToken: 'refresh-a',
        userId: '@alice:example.org',
        deviceId: 'DEVICE_A',
        displayName: 'Alice',
      );

      await markSessionRemoved('@alice:example.org');
      await completePendingSessionRemovals(dataDir: '/tmp/matter-data');

      expect(await loadAllSessions(), isEmpty);
      expect(rustApi.sdkCleanupCalls, [
        (userId: '@alice:example.org', dataDir: '/tmp/matter-data'),
      ]);
      await completePendingSessionRemovals(dataDir: '/tmp/matter-data');
      expect(rustApi.sdkCleanupCalls, hasLength(1));

      final prefs = await SharedPreferences.getInstance();
      expect(jsonDecode(prefs.getString('multi_sessions')!), isEmpty);
      expect(prefs.getString('active_user_id'), isNull);
      expect(
        (jsonDecode(prefs.getString('session_display_names')!) as Map)
            .containsKey('@alice:example.org'),
        isFalse,
      );
      final secure = FlutterSecureStorage();
      expect(
        await secure.read(
          key:
              'matrix_access_token_${base64Url.encode(utf8.encode('@alice:example.org'))}',
        ),
        isNull,
      );
      expect(
        await secure.read(
          key:
              'matrix_refresh_token_${base64Url.encode(utf8.encode('@alice:example.org'))}',
        ),
        isNull,
      );

      await addSession(
        homeserver: 'https://example.org',
        accessToken: 'token-b',
        userId: '@alice:example.org',
        deviceId: 'DEVICE_B',
        displayName: 'Alice',
      );

      final sessions = await loadAllSessions();
      expect(sessions.single.deviceId, 'DEVICE_B');
      expect(sessions.single.accessToken, 'token-b');
    });

    test('persistSessionTokens replaces rotated tokens', () async {
      await addSession(
        homeserver: 'https://example.org',
        accessToken: 'token-a',
        refreshToken: 'refresh-a',
        userId: '@alice:example.org',
        deviceId: 'DEVICE_A',
        displayName: 'Alice',
      );

      await persistSessionTokens(
        userId: '@alice:example.org',
        accessToken: 'token-b',
        refreshToken: 'refresh-b',
      );

      final sessions = await loadAllSessions();
      expect(sessions.single.accessToken, 'token-b');
      expect(sessions.single.refreshToken, 'refresh-b');
    });

    test('loadAllSessions skips sessions with missing tokens', () async {
      SharedPreferences.setMockInitialValues({
        'multi_sessions': jsonEncode([
          {
            'homeserver_url': 'https://example.org',
            'user_id': '@alice:example.org',
            'device_id': 'DEVICE_A',
          },
        ]),
      });

      final sessions = await loadAllSessions();
      expect(sessions, isEmpty);
    });

    test(
      'loadAllSessions keeps valid sessions after a malformed entry',
      () async {
        await addSession(
          homeserver: 'https://example.org',
          accessToken: 'token-a',
          userId: '@alice:example.org',
          deviceId: 'DEVICE_A',
          displayName: 'Alice',
        );
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'multi_sessions',
          jsonEncode([
            {'user_id': 42},
            {
              'homeserver_url': 'https://example.org',
              'user_id': '@alice:example.org',
              'device_id': 'DEVICE_A',
            },
          ]),
        );

        final sessions = await loadAllSessions();
        expect(sessions.single.userId, '@alice:example.org');
      },
    );

    test('removeSession deletes metadata, token and display name', () async {
      await addSession(
        homeserver: 'https://example.org',
        accessToken: 'token-a',
        userId: '@alice:example.org',
        deviceId: 'DEVICE_A',
        displayName: 'Alice',
      );
      final seededPrefs = await SharedPreferences.getInstance();
      await seededPrefs.setStringList('ignored_users_v1_@alice:example.org', [
        '@blocked:example.org',
      ]);

      await removeSession('@alice:example.org');

      final sessions = await loadAllSessions();
      expect(sessions, isEmpty);

      final prefs = await SharedPreferences.getInstance();
      final names = jsonDecode(prefs.getString('session_display_names')!);
      expect(names.containsKey('@alice:example.org'), isFalse);

      final secure = FlutterSecureStorage();
      final token = await secure.read(
        key:
            'matrix_access_token_${base64Url.encode(utf8.encode('@alice:example.org'))}',
      );
      expect(token, isNull);
      final refreshToken = await secure.read(
        key:
            'matrix_refresh_token_${base64Url.encode(utf8.encode('@alice:example.org'))}',
      );
      expect(refreshToken, isNull);
      expect(
        prefs.getStringList('ignored_users_v1_@alice:example.org'),
        isNull,
      );
    });

    test('removeSession switches active user when another exists', () async {
      await addSession(
        homeserver: 'https://example.org',
        accessToken: 'token-a',
        userId: '@alice:example.org',
        deviceId: 'DEVICE_A',
        displayName: 'Alice',
      );
      await addSession(
        homeserver: 'https://matrix.org',
        accessToken: 'token-b',
        userId: '@bob:matrix.org',
        deviceId: 'DEVICE_B',
        displayName: 'Bob',
      );

      await removeSession('@alice:example.org');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('active_user_id'), '@bob:matrix.org');
    });

    test('removeSession clears that account markdown source cache', () async {
      const store = MarkdownSourceStore();
      await addSession(
        homeserver: 'https://example.org',
        accessToken: 'token-a',
        userId: '@alice:example.org',
        deviceId: 'DEVICE_A',
        displayName: 'Alice',
      );
      await addSession(
        homeserver: 'https://matrix.org',
        accessToken: 'token-b',
        userId: '@bob:matrix.org',
        deviceId: 'DEVICE_B',
        displayName: 'Bob',
      );
      for (final userId in ['@alice:example.org', '@bob:matrix.org']) {
        await store.save(
          userId: userId,
          roomId: '!room:example.org',
          eventId: r'$event',
          source: '**$userId**',
          body: userId,
          formattedBody: null,
          persist: true,
        );
      }

      await removeSession('@alice:example.org');

      expect(
        await store.load(
          userId: '@alice:example.org',
          roomId: '!room:example.org',
          eventId: r'$event',
          body: '@alice:example.org',
          formattedBody: null,
          allowPersistence: true,
        ),
        isNull,
      );
      expect(
        await store.load(
          userId: '@bob:matrix.org',
          roomId: '!room:example.org',
          eventId: r'$event',
          body: '@bob:matrix.org',
          formattedBody: null,
          allowPersistence: true,
        ),
        '**@bob:matrix.org**',
      );
    });

    test('removeSession records homeservers in the removal marker', () async {
      await addSession(
        homeserver: 'https://example.org',
        accessToken: 'token-a',
        userId: '@alice:example.org',
        deviceId: 'DEVICE_A',
        displayName: 'Alice',
      );

      await removeSession('@alice:example.org');

      final prefs = await SharedPreferences.getInstance();
      final marker =
          jsonDecode(
                prefs.getString(_removedSessionTestKey('@alice:example.org'))!,
              )
              as Map<String, dynamic>;
      expect(marker['homeservers'], ['https://example.org']);
    });

    test(
      'a removal retry still clears the media cache via the marker homeservers',
      () async {
        const userId = '@alice:example.org';
        const homeserver = 'https://example.org';
        // A first removal attempt dropped the account's metadata and wrote
        // the removal marker (with its homeservers) but was killed before
        // the media-cache cleanup; the startup retry now runs with the
        // metadata already gone from multi_sessions.
        SharedPreferences.setMockInitialValues({
          'multi_sessions': jsonEncode([
            {
              'homeserver_url': 'https://matrix.org',
              'user_id': '@bob:matrix.org',
              'device_id': 'DEVICE_B',
            },
          ]),
          _removedSessionTestKey(userId): jsonEncode({
            'homeservers': [homeserver],
          }),
        });
        final scope = base64Url
            .encode(utf8.encode('$userId|$homeserver'))
            .replaceAll('=', '');
        final cacheDir = Directory(
          '/tmp/matter_auth_provider_test/matter-auth-media-$scope',
        );
        if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);

        await removeSession(userId);

        // The retry cleared the media cache: the per-homeserver store was
        // touched even though the metadata is no longer in multi_sessions.
        expect(cacheDir.existsSync(), isTrue);
        // The marker keeps the homeservers for any further retry.
        final prefs = await SharedPreferences.getInstance();
        final marker =
            jsonDecode(prefs.getString(_removedSessionTestKey(userId))!)
                as Map<String, dynamic>;
        expect(marker['homeservers'], [homeserver]);
      },
    );

    test('corrupt session metadata does not abort a marked removal', () async {
      const userId = '@alice:example.org';
      // The marker is already persisted (as in every real flow); the
      // metadata JSON is corrupt. The removal must finish instead of
      // aborting, which would strand the account behind the marker forever.
      SharedPreferences.setMockInitialValues({
        'multi_sessions': '{not valid json',
        'active_user_id': userId,
        // Legacy marker format (a bare boolean) must not crash either.
        _removedSessionTestKey(userId): true,
      });

      await removeSession(userId);

      final prefs = await SharedPreferences.getInstance();
      // The corrupt JSON is left untouched (other accounts' metadata is not
      // silently dropped)...
      expect(prefs.getString('multi_sessions'), '{not valid json');
      // ...but the removal completed: the marker was upgraded to the new
      // format and no active account remains.
      expect(prefs.getString(_removedSessionTestKey(userId)), isNotNull);
      expect(prefs.getString('active_user_id'), isNull);
    });

    test('clearAllSessions wipes everything', () async {
      const store = MarkdownSourceStore();
      await addSession(
        homeserver: 'https://example.org',
        accessToken: 'token-a',
        userId: '@alice:example.org',
        deviceId: 'DEVICE_A',
        displayName: 'Alice',
      );
      await store.save(
        userId: '@alice:example.org',
        roomId: '!room:example.org',
        eventId: r'$event',
        source: '**hello**',
        body: 'hello',
        formattedBody: null,
        persist: true,
      );
      final seededPrefs = await SharedPreferences.getInstance();
      await seededPrefs.setStringList('ignored_users_v1_@alice:example.org', [
        '@blocked:example.org',
      ]);

      await clearAllSessions();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('multi_sessions'), isNull);
      expect(prefs.getString('session_display_names'), isNull);
      expect(prefs.getString('active_user_id'), isNull);
      expect(
        prefs.getStringList('ignored_users_v1_@alice:example.org'),
        isNull,
      );

      final secure = FlutterSecureStorage();
      final all = await secure.readAll();
      expect(all, isEmpty);
      expect(
        await store.load(
          userId: '@alice:example.org',
          roomId: '!room:example.org',
          eventId: r'$event',
          body: 'hello',
          formattedBody: null,
          allowPersistence: true,
        ),
        isNull,
      );
    });

    test('migrateLegacySession converts old keys to multi-session', () async {
      SharedPreferences.setMockInitialValues({
        'session_homeserver': 'https://legacy.org',
        'session_access_token': 'legacy-token',
        'session_user_id': '@legacy:example.org',
        'session_device_id': 'LEGACY',
        'session_display_name': 'Legacy User',
      });

      final migrated = await migrateLegacySession();
      expect(migrated, isTrue);

      final sessions = await loadAllSessions();
      expect(sessions.single.userId, '@legacy:example.org');
      expect(sessions.single.accessToken, 'legacy-token');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('session_homeserver'), isNull);
      expect(prefs.getString('session_access_token'), isNull);
    });

    test('migrateLegacySession returns false when keys are missing', () async {
      SharedPreferences.setMockInitialValues({});
      final migrated = await migrateLegacySession();
      expect(migrated, isFalse);
    });
  });
}
