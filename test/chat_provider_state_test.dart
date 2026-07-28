import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/providers/connection_provider.dart';
import 'package:matter/providers/message_cache_persistence.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';

class _FakeRustApi implements RustLibApi {
  final syncEvents = StreamController<rust.SyncEvent>.broadcast();
  int ignoredUsersCalls = 0;
  List<String> ignoredUsers = const [];
  Object? ignoredUsersError;
  Completer<List<String>>? pendingIgnoredUsers;
  int getMessagesCalls = 0;
  int markRoomAsReadCalls = 0;
  int chatRoomsCalls = 0;
  int ungroupedRoomsCalls = 0;
  int spaceChildrenCalls = 0;
  int searchRoomsCalls = 0;
  int knockRequestsCalls = 0;
  int membersCalls = 0;
  Completer<List<rust.ChatMessage>>? pendingMessages;

  @override
  rust.ConnectionStatus crateApiMatrixGetConnectionStatus() {
    return rust.ConnectionStatus.connected;
  }

  @override
  Future<List<String>> crateApiMatrixGetIgnoredUsers() async {
    ignoredUsersCalls++;
    if (ignoredUsersError case final error?) throw error;
    final pending = pendingIgnoredUsers;
    if (pending != null) return pending.future;
    return ignoredUsers;
  }

  @override
  Future<List<rust.ChatMessage>> crateApiMatrixGetMessages({
    required String roomId,
  }) {
    getMessagesCalls++;
    return pendingMessages?.future ?? Future.value(const []);
  }

  @override
  Future<bool> crateApiMatrixIsRoomEncrypted({required String roomId}) async =>
      false;

  @override
  Future<void> crateApiMatrixMarkRoomAsRead({required String roomId}) async {
    markRoomAsReadCalls++;
  }

  @override
  Future<List<rust.ChatRoom>> crateApiMatrixGetChatRooms() async {
    chatRoomsCalls++;
    return const [];
  }

  @override
  Future<List<rust.ChatRoom>> crateApiMatrixGetUngroupedRooms() async {
    ungroupedRoomsCalls++;
    return const [];
  }

  @override
  Future<List<rust.ChatRoom>> crateApiMatrixGetSpaceChildren({
    required String spaceId,
  }) async {
    spaceChildrenCalls++;
    return const [];
  }

  @override
  Future<List<rust.ChatRoom>> crateApiMatrixSearchRooms({
    required String query,
  }) async {
    searchRoomsCalls++;
    return const [];
  }

  @override
  Future<List<rust.KnockRequest>> crateApiMatrixGetRoomKnockRequests({
    required String roomId,
  }) async {
    knockRequestsCalls++;
    return const [];
  }

  @override
  Future<List<rust.Contact>> crateApiMatrixGetRoomMembers({
    required String roomId,
  }) async {
    membersCalls++;
    return const [];
  }

  @override
  Stream<rust.SyncEvent> crateApiMatrixWatchSyncEvents() => syncEvents.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
  }
}

Future<WidgetRef> _captureRef(WidgetTester tester) async {
  WidgetRef? ref;
  await tester.pumpWidget(
    ProviderScope(
      child: Consumer(
        builder: (context, r, _) {
          ref = r;
          return Container();
        },
      ),
    ),
  );
  return ref!;
}

rust.ChatMessage _message(String id, String timestamp) => rust.ChatMessage(
  id: id,
  senderId: '@alice:example.org',
  senderName: 'Alice',
  content: id,
  mentionedUserIds: const [],
  mentionsRoom: false,
  timestamp: timestamp,
  isMe: false,
  msgType: rust.MessageType.text,
  isEdited: false,
  editHistory: const [],
  reactions: const [],
  readers: const [],
  totalMembers: 2,
);

rust.ChatRoom _room(String id, {bool isEncrypted = false}) => rust.ChatRoom(
  id: id,
  name: 'Room',
  lastMessage: '',
  lastMessageTime: '0',
  unreadCount: 0,
  isMarkedUnread: false,
  roomType: 'group',
  isEncrypted: isEncrypted,
  isMuted: false,
  roomState: 'joined',
);

final _refreshMessagesRefProvider = FutureProvider.family<void, String>(
  (ref, roomId) => refreshMessagesRef(ref, roomId),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FakeRustApi rustApi;

  setUpAll(() {
    rustApi = _FakeRustApi();
    RustLib.initMock(api: rustApi);
  });

  tearDownAll(() async {
    await rustApi.syncEvents.close();
    RustLib.dispose();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    rustApi.ignoredUsersCalls = 0;
    rustApi.ignoredUsers = const [];
    rustApi.ignoredUsersError = null;
    rustApi.pendingIgnoredUsers = null;
    rustApi.getMessagesCalls = 0;
    rustApi.markRoomAsReadCalls = 0;
    rustApi.chatRoomsCalls = 0;
    rustApi.ungroupedRoomsCalls = 0;
    rustApi.spaceChildrenCalls = 0;
    rustApi.searchRoomsCalls = 0;
    rustApi.knockRequestsCalls = 0;
    rustApi.pendingMessages = null;
  });

  group('clearActiveSessionState', () {
    testWidgets('resets session-related providers', (tester) async {
      final ref = await _captureRef(tester);

      ref.read(isLoggedInProvider.notifier).value = true;
      ref.read(currentUserProvider.notifier).value = const CurrentUser(
        id: '@alice:example.org',
        displayName: 'Alice',
        homeserver: 'https://example.org',
      );
      ref.read(currentAccessTokenProvider.notifier).value = 'token';
      ref.read(activeUserIdProvider.notifier).value = '@alice:example.org';
      ref.read(connectionProvider.notifier).value =
          AppConnectionState.connected;

      clearActiveSessionState(ref);

      expect(ref.read(isLoggedInProvider), isFalse);
      expect(ref.read(currentUserProvider), isNull);
      expect(ref.read(currentAccessTokenProvider), isNull);
      expect(ref.read(activeUserIdProvider), isNull);
      expect(ref.read(connectionProvider), AppConnectionState.disconnected);
    });

    testWidgets('can mark session ready when requested', (tester) async {
      final ref = await _captureRef(tester);

      clearActiveSessionState(ref, markSessionReady: true);

      expect(ref.read(sessionReadyProvider), isTrue);
    });
  });

  group('invalidateSessionCollections', () {
    testWidgets('resets room-local optimistic state', (tester) async {
      final ref = await _captureRef(tester);
      const roomId = '!room:example.org';
      ref
          .read(roomUnreadOverrideProvider(roomId).notifier)
          .value = const RoomUnreadOverride(
        unread: true,
        baselineUnreadCount: 0,
        baselineMarkedUnread: false,
      );
      ref.read(roomAutoReadSuppressedProvider(roomId).notifier).value = true;

      invalidateSessionCollections(ref);
      await tester.pump();

      expect(ref.read(roomUnreadOverrideProvider(roomId)), isNull);
      expect(ref.read(roomAutoReadSuppressedProvider(roomId)), isFalse);
    });
  });

  testWidgets('refreshes ignored users only for their sync event', (
    tester,
  ) async {
    final container = ProviderContainer();
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    final syncSubscription = container.listen(
      syncStreamProvider,
      (_, _) {},
      fireImmediately: true,
    );
    final ignoredSubscription = container.listen(
      ignoredUserIdsProvider,
      (_, _) {},
      fireImmediately: true,
    );

    await container.read(ignoredUserIdsProvider.future);
    // The provider resolves with the persisted snapshot first; the network
    // refresh happens in the background.
    await tester.pump();
    expect(rustApi.ignoredUsersCalls, 1);

    rustApi.syncEvents.add(const rust.SyncEvent.syncCompleted());
    await tester.pump();
    expect(rustApi.ignoredUsersCalls, 1);

    rustApi.syncEvents.add(const rust.SyncEvent.ignoredUsersChanged());
    await tester.pump();
    await container.read(ignoredUserIdsProvider.future);
    await tester.pump();
    expect(rustApi.ignoredUsersCalls, 2);

    ignoredSubscription.close();
    syncSubscription.close();
    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
    'ignored users stay unknown without a snapshot when the fetch fails',
    (tester) async {
      rustApi.ignoredUsersError = StateError('offline');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(sessionReadyProvider.notifier).value = true;
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      // No persisted snapshot and a failing fetch: the provider must surface
      // an error (unknown) rather than silently resolving to an empty list.
      await expectLater(
        container.read(ignoredUserIdsProvider.future),
        throwsStateError,
      );
      expect(rustApi.ignoredUsersCalls, 1);

      container.dispose();
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets('a confirmed ignore change survives a failing refresh', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'ignored_users_v1_@alice:example.org': const ['@a:example.org'],
    });
    rustApi.ignoredUsers = const ['@a:example.org'];

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    expect(await container.read(ignoredUserIdsProvider.future), {
      '@a:example.org',
    });
    await tester.pump();

    // The server-side ignore succeeded; the returned full list is written
    // through to the local snapshot so timelines filter the sender
    // immediately. The server now holds the change as well.
    await persistIgnoredUserList('@alice:example.org', const {
      '@a:example.org',
      '@b:example.org',
    });
    rustApi.ignoredUsers = const ['@a:example.org', '@b:example.org'];
    container.invalidate(ignoredUserIdsProvider);
    expect(await container.read(ignoredUserIdsProvider.future), {
      '@a:example.org',
      '@b:example.org',
    });

    // A failing refresh afterwards must not restore the pre-change list.
    rustApi.ignoredUsersError = StateError('offline');
    container.invalidate(ignoredUserIdsProvider);
    await tester.pump();
    expect(await container.read(ignoredUserIdsProvider.future), {
      '@a:example.org',
      '@b:example.org',
    });

    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
    'an in-flight refresh cannot overwrite a newer confirmed change',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'ignored_users_v1_@alice:example.org': const ['@a:example.org'],
      });
      // The background refresh hangs until the test releases it.
      final refresh = Completer<List<String>>();
      rustApi.pendingIgnoredUsers = refresh;

      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(sessionReadyProvider.notifier).value = true;
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      // Resolves with the persisted snapshot; the refresh fetch is now in
      // flight and pending.
      expect(await container.read(ignoredUserIdsProvider.future), {
        '@a:example.org',
      });

      // The server-side ignore succeeds and its full post-write list is
      // written through while the earlier refresh is still pending.
      await persistIgnoredUserList('@alice:example.org', const {
        '@a:example.org',
        '@b:example.org',
      });

      // The stale refresh now completes with the pre-change list; it must
      // not overwrite the newer write-through.
      rustApi.pendingIgnoredUsers = null;
      rustApi.ignoredUsers = const ['@a:example.org', '@b:example.org'];
      refresh.complete(const ['@a:example.org']);
      await tester.pump();

      container.invalidate(ignoredUserIdsProvider);
      expect(await container.read(ignoredUserIdsProvider.future), {
        '@a:example.org',
        '@b:example.org',
      });

      container.dispose();
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets('a first load superseded by a change serves the newer snapshot', (
    tester,
  ) async {
    // No persisted snapshot: the provider waits on the authoritative
    // fetch, which hangs until the test releases it.
    final firstFetch = Completer<List<String>>();
    rustApi.pendingIgnoredUsers = firstFetch;

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    final future = container.read(ignoredUserIdsProvider.future);
    // Let the provider reach the pending fetch (version captured) before
    // the change lands.
    await tester.pump();

    // A confirmed ignore change (persisting the full post-write list)
    // lands while the first fetch is still in flight.
    await persistIgnoredUserList('@alice:example.org', const {
      '@a:example.org',
      '@b:example.org',
    });

    // The stale first response must not become the provider state.
    rustApi.pendingIgnoredUsers = null;
    firstFetch.complete(const ['@a:example.org']);
    expect(await future, {'@a:example.org', '@b:example.org'});

    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
    'a first load publishes the newer snapshot when a change lands mid-persist',
    (tester) async {
      // No persisted snapshot: the provider waits on the authoritative
      // fetch, which hangs until the test releases it.
      final firstFetch = Completer<List<String>>();
      rustApi.pendingIgnoredUsers = firstFetch;

      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(sessionReadyProvider.notifier).value = true;
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      final future = container.read(ignoredUserIdsProvider.future);
      // Let the provider reach the pending fetch (version captured).
      await tester.pump();

      // Releasing the fetch lets the provider pass its first version check
      // and start persisting. The confirmed change is scheduled one
      // microtask later, landing while that persist is in flight — the
      // provider must still not publish the stale response.
      firstFetch.complete(const ['@a:example.org']);
      late Future<void> writeThrough;
      scheduleMicrotask(() {
        writeThrough = persistIgnoredUserList('@alice:example.org', const {
          '@a:example.org',
          '@b:example.org',
        });
      });
      expect(await future, {'@a:example.org', '@b:example.org'});
      await writeThrough;

      container.dispose();
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets('ignored users fall back to the persisted list on failure', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'ignored_users_v1_@alice:example.org': const ['@blocked:example.org'],
    });
    rustApi.ignoredUsersError = StateError('offline');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    final ids = await container.read(ignoredUserIdsProvider.future);
    await tester.pump();
    // A failed refresh must not degrade into "nobody is ignored".
    expect(ids, {'@blocked:example.org'});
    expect(rustApi.ignoredUsersCalls, 1);

    // Once the server is reachable again the fresh list wins and persists.
    rustApi.ignoredUsersError = null;
    rustApi.ignoredUsers = const ['@blocked:example.org', '@spam:example.org'];
    container.invalidate(ignoredUserIdsProvider);
    await container.read(ignoredUserIdsProvider.future);
    await tester.pump();
    await tester.pump();
    final refreshed = await container.read(ignoredUserIdsProvider.future);
    expect(refreshed, {'@blocked:example.org', '@spam:example.org'});

    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('room-list events refresh every room collection', (tester) async {
    final container = ProviderContainer();
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    final subscriptions = <ProviderSubscription<dynamic>>[
      container.listen(chatRoomsProvider, (_, _) {}, fireImmediately: true),
      container.listen(
        ungroupedRoomsProvider,
        (_, _) {},
        fireImmediately: true,
      ),
      container.listen(
        spaceChildrenProvider('!space:example.org'),
        (_, _) {},
        fireImmediately: true,
      ),
      container.listen(
        searchRoomsProvider('project'),
        (_, _) {},
        fireImmediately: true,
      ),
      container.listen(
        roomKnockRequestsProvider('!room:example.org'),
        (_, _) {},
        fireImmediately: true,
      ),
      container.listen(
        roomMembersProvider('!room:example.org'),
        (_, _) {},
        fireImmediately: true,
      ),
      container.listen(syncStreamProvider, (_, _) {}, fireImmediately: true),
    ];
    await tester.pump();
    expect(rustApi.chatRoomsCalls, 1);
    expect(rustApi.ungroupedRoomsCalls, 1);
    expect(rustApi.spaceChildrenCalls, 1);
    expect(rustApi.searchRoomsCalls, 1);
    expect(rustApi.knockRequestsCalls, 1);
    expect(rustApi.membersCalls, 1);

    rustApi.syncEvents.add(const rust.SyncEvent.roomListChanged());
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    expect(rustApi.chatRoomsCalls, 2);
    expect(rustApi.ungroupedRoomsCalls, 2);
    expect(rustApi.spaceChildrenCalls, 2);
    expect(rustApi.searchRoomsCalls, 2);
    expect(rustApi.knockRequestsCalls, 2);
    expect(rustApi.membersCalls, 2);

    for (final subscription in subscriptions) {
      subscription.close();
    }
    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('marks a newly refreshed current-room message as read', (
    tester,
  ) async {
    const roomId = '!current:example.org';
    final container = ProviderContainer();
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    container.read(currentRoomIdProvider.notifier).value = roomId;
    final subscription = container.listen(
      syncStreamProvider,
      (_, _) {},
      fireImmediately: true,
    );

    rustApi.syncEvents.add(const rust.SyncEvent.messageSent(roomId: roomId));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();

    expect(rustApi.getMessagesCalls, 1);
    expect(rustApi.markRoomAsReadCalls, 1);

    subscription.close();
    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('keeps an explicitly unread current room unread on refresh', (
    tester,
  ) async {
    const roomId = '!unread:example.org';
    final container = ProviderContainer();
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    container.read(currentRoomIdProvider.notifier).value = roomId;
    container.read(roomAutoReadSuppressedProvider(roomId).notifier).value =
        true;
    final subscription = container.listen(
      syncStreamProvider,
      (_, _) {},
      fireImmediately: true,
    );

    rustApi.syncEvents.add(const rust.SyncEvent.messageSent(roomId: roomId));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();

    expect(rustApi.getMessagesCalls, 1);
    expect(rustApi.markRoomAsReadCalls, 0);

    subscription.close();
    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('does not mark read after the refreshed room was closed', (
    tester,
  ) async {
    const roomId = '!closed:example.org';
    final messages = Completer<List<rust.ChatMessage>>();
    rustApi.pendingMessages = messages;
    final container = ProviderContainer();
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    container.read(currentRoomIdProvider.notifier).value = roomId;
    final subscription = container.listen(
      syncStreamProvider,
      (_, _) {},
      fireImmediately: true,
    );

    rustApi.syncEvents.add(const rust.SyncEvent.messageSent(roomId: roomId));
    await tester.pump(const Duration(milliseconds: 150));
    expect(rustApi.getMessagesCalls, 1);

    container.read(currentRoomIdProvider.notifier).value = null;
    messages.complete(const []);
    await tester.pump();
    await tester.pump();

    expect(rustApi.markRoomAsReadCalls, 0);

    subscription.close();
    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  group('bootstrapActiveSessionSync', () {
    testWidgets('retries until the third sync attempt succeeds', (
      tester,
    ) async {
      final ref = await _captureRef(tester);
      var syncAttempts = 0;
      var startSyncCalls = 0;
      final delays = <Duration>[];

      await bootstrapActiveSessionSyncForTest(
        ref,
        attemptLabel: 'test sync',
        startSyncLabel: 'test start sync',
        syncOnce: () async {
          syncAttempts++;
          if (syncAttempts < 3) throw StateError('transient failure');
        },
        startSync: () async {
          startSyncCalls++;
        },
        delay: (duration) async {
          delays.add(duration);
        },
      );

      expect(syncAttempts, 3);
      expect(delays, const [Duration(seconds: 2), Duration(seconds: 4)]);
      expect(startSyncCalls, 1);
      expect(ref.read(connectionProvider), AppConnectionState.connected);
    });

    testWidgets('reports disconnected after all initial sync attempts fail', (
      tester,
    ) async {
      final ref = await _captureRef(tester);
      var syncAttempts = 0;
      var startSyncCalls = 0;

      await bootstrapActiveSessionSyncForTest(
        ref,
        attemptLabel: 'test sync',
        startSyncLabel: 'test start sync',
        syncOnce: () async {
          syncAttempts++;
          throw StateError('offline');
        },
        startSync: () async {
          startSyncCalls++;
        },
        delay: (_) async {},
      );

      expect(syncAttempts, 3);
      expect(startSyncCalls, 1);
      expect(ref.read(connectionProvider), AppConnectionState.disconnected);
    });

    testWidgets('reports disconnected when starting the sync loop fails', (
      tester,
    ) async {
      final ref = await _captureRef(tester);

      await bootstrapActiveSessionSyncForTest(
        ref,
        attemptLabel: 'test sync',
        startSyncLabel: 'test start sync',
        syncOnce: () async {},
        startSync: () async => throw StateError('start failed'),
        delay: (_) async {},
      );

      expect(ref.read(connectionProvider), AppConnectionState.disconnected);
    });
  });

  group('primeMessageCache', () {
    testWidgets('loads the persisted snapshot into the cache', (tester) async {
      const roomId = '!room:example.org';
      const namespace = '@alice:example.org';
      final message = _message(r'$cached', '100');
      final encoded = jsonEncode([chatMessageToMap(message)]);

      SharedPreferences.setMockInitialValues({
        'msg_cache_v2_$namespace::$roomId': encoded,
      });

      WidgetRef? ref;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            chatRoomsProvider.overrideWith((ref) async => [_room(roomId)]),
          ],
          child: Consumer(
            builder: (context, r, _) {
              ref = r;
              return Container();
            },
          ),
        ),
      );
      final widgetRef = ref!;
      await widgetRef.read(chatRoomsProvider.future);
      widgetRef.read(activeUserIdProvider.notifier).value = namespace;

      await primeMessageCache(widgetRef, roomId);

      expect(widgetRef.read(messageCacheProvider(roomId)).length, 1);
      expect(
        widgetRef.read(messageCacheProvider(roomId)).single.id,
        r'$cached',
      );
      expect(widgetRef.read(messageCachePrimedProvider(roomId)), isTrue);
    });

    testWidgets('clears stale cache when the namespace changes', (
      tester,
    ) async {
      const roomId = '!room:example.org';
      final ref = await _captureRef(tester);
      ref.read(activeUserIdProvider.notifier).value = '@alice:example.org';
      ref.read(messageCacheProvider(roomId).notifier).value = [
        _message(r'$stale', '100'),
      ];
      ref.read(messageCacheOwnerProvider(roomId).notifier).value =
          '@bob:example.org';

      await primeMessageCache(ref, roomId);

      expect(ref.read(messageCacheProvider(roomId)), isEmpty);
      expect(ref.read(messageCacheOwnerProvider(roomId)), '@alice:example.org');
    });

    testWidgets('only primes once per room', (tester) async {
      const roomId = '!room:example.org';
      final ref = await _captureRef(tester);
      ref.read(activeUserIdProvider.notifier).value = '@alice:example.org';
      ref.read(messageCachePrimedProvider(roomId).notifier).value = true;

      await primeMessageCache(ref, roomId);

      // No persisted cache exists, but priming was skipped so the provider stays empty.
      expect(ref.read(messageCacheProvider(roomId)), isEmpty);
    });
  });

  group('message refresh', () {
    testWidgets('drops a network refresh after an account switch', (
      tester,
    ) async {
      const roomId = '!room:example.org';
      final pendingMessages = Completer<List<rust.ChatMessage>>();
      WidgetRef? ref;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            messagesProvider(
              roomId,
            ).overrideWith((ref) => pendingMessages.future),
          ],
          child: Consumer(
            builder: (context, r, _) {
              ref = r;
              return Container();
            },
          ),
        ),
      );
      final widgetRef = ref!;
      widgetRef.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      final refresh = refreshMessagesFromNetwork(widgetRef, roomId);
      widgetRef.read(activeUserIdProvider.notifier).value = '@bob:example.org';
      pendingMessages.complete([_message(r'$alice', '100')]);
      await refresh;

      expect(widgetRef.read(messageCacheProvider(roomId)), isEmpty);
      expect(widgetRef.read(messageCacheOwnerProvider(roomId)), isNull);
    });

    testWidgets('drops a sync refresh after an account switch', (tester) async {
      const roomId = '!room:example.org';
      final pendingMessages = Completer<List<rust.ChatMessage>>();
      WidgetRef? ref;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            messagesProvider(
              roomId,
            ).overrideWith((ref) => pendingMessages.future),
          ],
          child: Consumer(
            builder: (context, r, _) {
              ref = r;
              return Container();
            },
          ),
        ),
      );
      final widgetRef = ref!;
      widgetRef.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      final refresh = widgetRef.read(
        _refreshMessagesRefProvider(roomId).future,
      );
      widgetRef.read(activeUserIdProvider.notifier).value = '@bob:example.org';
      pendingMessages.complete([_message(r'$alice', '100')]);
      await refresh;

      expect(widgetRef.read(messageCacheProvider(roomId)), isEmpty);
      expect(widgetRef.read(messageCacheOwnerProvider(roomId)), isNull);
    });
  });

  group('MXC URL cache', () {
    testWidgets('cachedResolvedMxcUrl reads from the in-memory cache', (
      tester,
    ) async {
      const mxc = 'mxc://example.org/image';
      final ref = await _captureRef(tester);
      ref.read(activeUserIdProvider.notifier).value = '@alice:example.org';
      ref.read(mxcUrlCacheProvider.notifier).value = {
        '@alice:example.org::mxc://example.org/image|96x96':
            'https://example.org/image.png',
      };

      final url = cachedResolvedMxcUrl(ref, mxc, width: 96, height: 96);
      expect(url, 'https://example.org/image.png');
    });

    testWidgets('cachedResolvedMxcUrl returns null for non-mxc URLs', (
      tester,
    ) async {
      final ref = await _captureRef(tester);
      expect(
        cachedResolvedMxcUrl(ref, 'https://example.org/image.png'),
        isNull,
      );
      expect(cachedResolvedMxcUrl(ref, null), isNull);
    });

    testWidgets('rememberResolvedMxcUrl updates the in-memory cache', (
      tester,
    ) async {
      const mxc = 'mxc://example.org/new';
      const httpUrl = 'https://example.org/new.png';
      final ref = await _captureRef(tester);
      ref.read(activeUserIdProvider.notifier).value = '@alice:example.org';

      rememberResolvedMxcUrl(ref, mxc, httpUrl);

      expect(ref.read(mxcUrlCacheProvider).values, contains(httpUrl));
    });
  });
}
