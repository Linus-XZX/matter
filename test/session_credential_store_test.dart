import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:matter/providers/session_credential_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  final supportDirectory = Directory(
    '/tmp/matter_session_credential_store_test',
  );

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({});
    if (await supportDirectory.exists()) {
      await supportDirectory.delete(recursive: true);
    }
    await supportDirectory.create(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getApplicationSupportDirectory') {
            return supportDirectory.path;
          }
          return null;
        });
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    if (await supportDirectory.exists()) {
      await supportDirectory.delete(recursive: true);
    }
  });

  test('recognizes Android Keystore unwrap failures', () {
    expect(
      isKeystoreFailure(
        'InvalidKeyException: Failed to unwrap key: OAEP_DECODING_ERROR',
      ),
      isTrue,
    );
    expect(isKeystoreFailure('Connection timed out'), isFalse);
  });

  test('compatibility mode is explicit and persistent', () async {
    expect(await isSessionCredentialCompatibilityModeEnabled(), isFalse);
    await enableSessionCredentialCompatibilityMode();
    expect(await isSessionCredentialCompatibilityModeEnabled(), isTrue);
    await disableSessionCredentialCompatibilityMode();
    expect(await isSessionCredentialCompatibilityModeEnabled(), isFalse);
  });

  test(
    'non-Android credential cleanup never opens the compatibility file',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      var secureDeleteCalled = false;

      await removeSessionCredentials(
        userId: '@alice:example.org',
        deleteSecureCredentials: () async => secureDeleteCalled = true,
      );

      expect(secureDeleteCalled, isTrue);
      expect(await isSessionCredentialCompatibilityModeEnabled(), isFalse);
    },
  );

  test('writes, replaces and deletes per-account credentials', () async {
    await writeCompatibilitySessionCredentials(
      userId: '@alice:example.org',
      accessToken: 'access-a',
      refreshToken: 'refresh-a',
    );
    await writeCompatibilitySessionCredentials(
      userId: '@bob:example.org',
      accessToken: 'access-b',
      refreshToken: null,
    );

    var alice = await readCompatibilitySessionCredentials('@alice:example.org');
    expect(alice?.accessToken, 'access-a');
    expect(alice?.refreshToken, 'refresh-a');
    expect(
      (await readCompatibilitySessionCredentials(
        '@bob:example.org',
      ))?.accessToken,
      'access-b',
    );

    await writeCompatibilitySessionCredentials(
      userId: '@alice:example.org',
      accessToken: 'access-a2',
      refreshToken: null,
    );
    alice = await readCompatibilitySessionCredentials('@alice:example.org');
    expect(alice?.accessToken, 'access-a2');
    expect(alice?.refreshToken, isNull);

    await deleteCompatibilitySessionCredentials('@alice:example.org');
    expect(
      await readCompatibilitySessionCredentials('@alice:example.org'),
      isNull,
    );
    expect(
      (await readCompatibilitySessionCredentials(
        '@bob:example.org',
      ))?.accessToken,
      'access-b',
    );
  });

  test('deleting credentials clears a corrupt compatibility file', () async {
    final credentialFile = File(
      '${supportDirectory.path}/session_credentials_compatibility_v1.json',
    );
    await credentialFile.writeAsString('{not valid json');

    await deleteCompatibilitySessionCredentials('@alice:example.org');

    expect(await credentialFile.exists(), isFalse);
  });

  test('writing credentials replaces a corrupt compatibility file', () async {
    final credentialFile = File(
      '${supportDirectory.path}/session_credentials_compatibility_v1.json',
    );
    await credentialFile.writeAsString('{not valid json');

    await writeCompatibilitySessionCredentials(
      userId: '@alice:example.org',
      accessToken: 'access-a',
      refreshToken: 'refresh-a',
    );

    final credentials = await readCompatibilitySessionCredentials(
      '@alice:example.org',
    );
    expect(credentials?.accessToken, 'access-a');
    expect(credentials?.refreshToken, 'refresh-a');
  });

  test('concurrent credential writes preserve every account', () async {
    await Future.wait([
      for (var index = 0; index < 20; index++)
        writeCompatibilitySessionCredentials(
          userId: '@user$index:example.org',
          accessToken: 'access-$index',
          refreshToken: index.isEven ? 'refresh-$index' : null,
        ),
    ]);

    for (var index = 0; index < 20; index++) {
      final credentials = await readCompatibilitySessionCredentials(
        '@user$index:example.org',
      );
      expect(credentials?.accessToken, 'access-$index');
      expect(
        credentials?.refreshToken,
        index.isEven ? 'refresh-$index' : isNull,
      );
    }
  });

  test('recovery preserves readable credentials before secure reset', () async {
    var resetCalled = false;

    final resetError = await recoverSessionCredentialStore(
      recoveredCredentials: const {
        '@alice:example.org': SessionCredentials(
          accessToken: 'access-a',
          refreshToken: 'refresh-a',
        ),
        '@bob:example.org': SessionCredentials(
          accessToken: 'access-b',
          refreshToken: null,
        ),
      },
      loadLatestCredentials: () async => const {
        '@alice:example.org': SessionCredentials(
          accessToken: 'access-a-latest',
          refreshToken: 'refresh-a-latest',
        ),
      },
      shouldResetSecureValues: (_) => true,
      resetSecureValues: () async => resetCalled = true,
    );

    expect(resetError, isNull);
    expect(resetCalled, isTrue);
    expect(await isSessionCredentialCompatibilityModeEnabled(), isTrue);
    expect(
      (await readCompatibilitySessionCredentials(
        '@alice:example.org',
      ))?.accessToken,
      'access-a-latest',
    );
    expect(
      (await readCompatibilitySessionCredentials(
        '@bob:example.org',
      ))?.accessToken,
      'access-b',
    );
  });

  test('credential removal clears compatibility and secure storage', () async {
    await enableSessionCredentialCompatibilityMode();
    await writeCompatibilitySessionCredentials(
      userId: '@alice:example.org',
      accessToken: 'access-a',
    );
    var secureDeleteCalled = false;

    await removeSessionCredentials(
      userId: '@alice:example.org',
      deleteSecureCredentials: () async => secureDeleteCalled = true,
    );

    expect(secureDeleteCalled, isTrue);
    expect(
      await readCompatibilitySessionCredentials('@alice:example.org'),
      isNull,
    );
  });

  test(
    'an interrupted recovery removes uncommitted plaintext credentials',
    () async {
      final credentialFile = File(
        '${supportDirectory.path}/session_credentials_compatibility_v1.json',
      );
      await credentialFile.writeAsString(
        '{"@alice:example.org":{"access_token":"access-a"}}',
      );
      SharedPreferences.setMockInitialValues({
        'session_credential_compatibility_mode_pending_v1': true,
      });

      expect(await isSessionCredentialCompatibilityModeEnabled(), isFalse);
      expect(await credentialFile.exists(), isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.containsKey('session_credential_compatibility_mode_pending_v1'),
        isFalse,
      );
    },
  );

  test('an interrupted commit keeps committed credentials', () async {
    final credentialFile = File(
      '${supportDirectory.path}/session_credentials_compatibility_v1.json',
    );
    await credentialFile.writeAsString(
      '{"@alice:example.org":{"access_token":"access-a"}}',
    );
    SharedPreferences.setMockInitialValues({
      'session_credential_compatibility_mode_v1': true,
      'session_credential_compatibility_mode_pending_v1': true,
    });

    expect(await isSessionCredentialCompatibilityModeEnabled(), isTrue);
    expect(
      (await readCompatibilitySessionCredentials(
        '@alice:example.org',
      ))?.accessToken,
      'access-a',
    );
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.containsKey('session_credential_compatibility_mode_pending_v1'),
      isFalse,
    );
  });

  test(
    'a failed secure reset does not discard recovered credentials',
    () async {
      final resetError = await recoverSessionCredentialStore(
        recoveredCredentials: const {
          '@alice:example.org': SessionCredentials(
            accessToken: 'access-a',
            refreshToken: null,
          ),
        },
        loadLatestCredentials: () async => const {},
        shouldResetSecureValues: (_) => true,
        resetSecureValues: () async => throw StateError('reset failed'),
      );

      expect(resetError, isA<StateError>());
      expect(await isSessionCredentialCompatibilityModeEnabled(), isTrue);
      expect(
        (await readCompatibilitySessionCredentials(
          '@alice:example.org',
        ))?.accessToken,
        'access-a',
      );
    },
  );

  test('credential file never uses token values as preference keys', () async {
    await writeCompatibilitySessionCredentials(
      userId: '@alice:example.org',
      accessToken: 'access-a',
      refreshToken: 'refresh-a',
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), isEmpty);
  });

  test('incomplete recovery keeps the secure store untouched', () async {
    var resetCalled = false;

    await recoverSessionCredentialStore(
      recoveredCredentials: const {
        '@alice:example.org': SessionCredentials(
          accessToken: 'access-a',
          refreshToken: null,
        ),
      },
      loadLatestCredentials: () async => const {},
      shouldResetSecureValues: (userIds) =>
          userIds.contains('@alice:example.org') &&
          userIds.contains('@bob:example.org'),
      resetSecureValues: () async => resetCalled = true,
    );

    expect(resetCalled, isFalse);
    expect(await isSessionCredentialCompatibilityModeEnabled(), isTrue);
    expect(
      (await readCompatibilitySessionCredentials(
        '@alice:example.org',
      ))?.accessToken,
      'access-a',
    );
  });
}
