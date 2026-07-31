import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/pinned_messages_page.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';

class _FakeRustApi implements RustLibApi {
  final List<Future<List<rust.ChatMessage>> Function()> _responses = [];
  final syncEvents = StreamController<rust.SyncEvent>.broadcast();
  Future<void> Function(String roomId)? subscribeHandler;
  Future<void> Function(String roomId)? unsubscribeHandler;
  int callCount = 0;
  /// Pending unpin toggle calls, in order; completes with the post-write
  /// pinned state when the test resolves them.
  final List<Completer<bool>> pendingToggles = [];
  int toggleCalls = 0;

  void reset(List<Future<List<rust.ChatMessage>> Function()> responses) {
    _responses
      ..clear()
      ..addAll(responses);
    callCount = 0;
    pendingToggles.clear();
    toggleCalls = 0;
    subscribeHandler = null;
    unsubscribeHandler = null;
  }

  @override
  Future<bool> crateApiMatrixTogglePinnedMessage({
    required String roomId,
    required String eventId,
  }) {
    toggleCalls++;
    final completer = Completer<bool>();
    pendingToggles.add(completer);
    return completer.future;
  }

  @override
  Future<List<rust.ChatMessage>> crateApiMatrixGetPinnedMessages({
    required String roomId,
  }) {
    callCount++;
    if (_responses.isEmpty) {
      throw StateError('No pinned-message response configured');
    }
    return _responses.removeAt(0)();
  }

  @override
  Stream<rust.SyncEvent> crateApiMatrixWatchSyncEvents() => syncEvents.stream;

  @override
  Future<String> crateApiMatrixSubscribeRoomForReceipts({
    required String roomId,
    String? accountUserId,
  }) async {
    await subscribeHandler?.call(roomId);
    return 'pinned-subscription';
  }

  @override
  Future<void> crateApiMatrixUnsubscribeRoomForReceipts({
    required String roomId,
    required String subscriptionId,
  }) => unsubscribeHandler?.call(roomId) ?? Future.value();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
  }
}

rust.ChatMessage _message(String id, String senderId, String content) {
  return rust.ChatMessage(
    id: id,
    senderId: senderId,
    senderName: senderId,
    content: content,
    mentionedUserIds: const [],
    mentionsRoom: false,
    timestamp: '1',
    isMe: false,
    msgType: rust.MessageType.text,
    isEdited: false,
    editHistory: const [],
    reactions: const [],
    readers: const [],
    totalMembers: 2,
  );
}

void main() {
  late _FakeRustApi api;

  setUpAll(() {
    api = _FakeRustApi();
    RustLib.initMock(api: api);
  });

  tearDownAll(() async {
    await api.syncEvents.close();
    RustLib.dispose();
  });

  testWidgets('hides pinned messages from ignored users', (tester) async {
    api.reset([
      () async => [
        _message(r'$blocked', '@blocked:example.org', 'Blocked message'),
        _message(r'$visible', '@alice:example.org', 'Visible message'),
      ],
    ]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ignoredUserIdsProvider.overrideWith(
            (ref) async => {'@blocked:example.org'},
          ),
        ],
        child: const MaterialApp(
          home: PinnedMessagesPage(roomId: '!room:example.org'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Visible message'), findsOneWidget);
    expect(find.text('Blocked message'), findsNothing);
  });

  testWidgets('empty state remains pull-to-refreshable', (tester) async {
    final refresh = Completer<List<rust.ChatMessage>>();
    api.reset([() async => [], () => refresh.future]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ignoredUserIdsProvider.overrideWith((ref) async => <String>{}),
        ],
        child: const MaterialApp(
          home: PinnedMessagesPage(roomId: '!room:example.org'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('暂无置顶消息'), findsOneWidget);
    expect(find.byType(CustomScrollView), findsOneWidget);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(api.callCount, 2);
    expect(find.text('暂无置顶消息'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    refresh.complete([
      _message(r'$refreshed', '@alice:example.org', 'Refreshed message'),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Refreshed message'), findsOneWidget);
  });

  testWidgets('failed load can be retried', (tester) async {
    api.reset([
      () async => throw Exception('offline'),
      () async => [
        _message(r'$retry', '@alice:example.org', 'Loaded after retry'),
      ],
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ignoredUserIdsProvider.overrideWith((ref) async => <String>{}),
        ],
        child: const MaterialApp(
          home: PinnedMessagesPage(roomId: '!room:example.org'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('加载失败:'), findsOneWidget);
    await tester.tap(find.textContaining('加载失败:'));
    await tester.pumpAndSettle();

    expect(api.callCount, 2);
    expect(find.text('Loaded after retry'), findsOneWidget);
  });

  testWidgets('failed background refresh marks retained messages as stale', (
    tester,
  ) async {
    api.reset([
      () async => [_message(r'$old', '@alice:example.org', 'Old pinned')],
      () async => throw Exception('offline'),
      () async => [_message(r'$new', '@alice:example.org', 'New pinned')],
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ignoredUserIdsProvider.overrideWith((ref) async => <String>{}),
        ],
        child: const MaterialApp(
          home: PinnedMessagesPage(roomId: '!room:example.org'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    api.syncEvents.add(
      const rust.SyncEvent.pinnedMessagesChanged(roomId: '!room:example.org'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Old pinned'), findsOneWidget);
    expect(find.text('刷新失败，当前显示上次结果'), findsOneWidget);
    expect(find.byTooltip('重试刷新'), findsOneWidget);

    await tester.tap(find.byTooltip('重试刷新'));
    await tester.pumpAndSettle();

    expect(find.text('刷新失败，当前显示上次结果'), findsNothing);
    expect(find.text('Old pinned'), findsNothing);
    expect(find.text('New pinned'), findsOneWidget);
  });

  testWidgets(
    'room pin changes refresh serially and retain the current messages',
    (tester) async {
      final refresh = Completer<List<rust.ChatMessage>>();
      api.reset([
        () async => [_message(r'$old', '@alice:example.org', 'Old pinned')],
        () => refresh.future,
        () async => [_message(r'$new', '@alice:example.org', 'New pinned')],
      ]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ignoredUserIdsProvider.overrideWith((ref) async => <String>{}),
          ],
          child: const MaterialApp(
            home: PinnedMessagesPage(roomId: '!room:example.org'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Old pinned'), findsOneWidget);

      api.syncEvents.add(
        const rust.SyncEvent.pinnedMessagesChanged(
          roomId: '!other:example.org',
        ),
      );
      api.syncEvents.add(const rust.SyncEvent.syncCompleted());
      await tester.pump();
      expect(api.callCount, 1);

      api.syncEvents.add(
        const rust.SyncEvent.pinnedMessagesChanged(roomId: '!room:example.org'),
      );
      await tester.pump();
      expect(api.callCount, 2);
      expect(find.text('Old pinned'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      api.syncEvents.add(
        const rust.SyncEvent.pinnedMessagesChanged(roomId: '!room:example.org'),
      );
      api.syncEvents.add(
        const rust.SyncEvent.pinnedMessagesChanged(roomId: '!room:example.org'),
      );
      await tester.pump();
      expect(api.callCount, 2);

      refresh.complete([
        _message(r'$middle', '@alice:example.org', 'Intermediate pinned'),
      ]);
      await tester.pumpAndSettle();

      expect(api.callCount, 3);
      expect(find.text('Old pinned'), findsNothing);
      expect(find.text('New pinned'), findsOneWidget);
    },
  );

  testWidgets('full refresh compensates for dropped pin events', (
    tester,
  ) async {
    api.reset([
      () async => [_message(r'$old', '@alice:example.org', 'Old pinned')],
      () async => [_message(r'$new', '@alice:example.org', 'New pinned')],
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ignoredUserIdsProvider.overrideWith((ref) async => <String>{}),
        ],
        child: const MaterialApp(
          home: PinnedMessagesPage(roomId: '!room:example.org'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    api.syncEvents.add(const rust.SyncEvent.syncCompleted());
    await tester.pump();
    expect(api.callCount, 1);

    api.syncEvents.add(const rust.SyncEvent.fullRefreshRequired());
    await tester.pumpAndSettle();

    expect(api.callCount, 2);
    expect(find.text('New pinned'), findsOneWidget);
  });

  testWidgets('dispose waits for room subscription before unsubscribing', (
    tester,
  ) async {
    final subscription = Completer<void>();
    final calls = <String>[];
    api.reset([() async => []]);
    api.subscribeHandler = (roomId) {
      calls.add('subscribe');
      return subscription.future;
    };
    api.unsubscribeHandler = (roomId) async {
      calls.add('unsubscribe');
    };

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ignoredUserIdsProvider.overrideWith((ref) async => <String>{}),
        ],
        child: const MaterialApp(
          home: PinnedMessagesPage(roomId: '!room:example.org'),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    expect(calls, ['subscribe']);

    subscription.complete();
    await tester.pump();

    expect(calls, ['subscribe', 'unsubscribe']);
    api.subscribeHandler = null;
    api.unsubscribeHandler = null;
  });

  testWidgets(
    'unpin removes the row optimistically and reloads after removal',
    (tester) async {
      api.reset([
        () async => [_message(r'$pinned', '@alice:example.org', 'Pinned')],
      ]);
      // The reload triggered by the completed removal.
      api._responses.add(() async => []);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ignoredUserIdsProvider.overrideWith((ref) async => <String>{}),
          ],
          child: const MaterialApp(
            home: PinnedMessagesPage(roomId: '!room:example.org'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Pinned'), findsOneWidget);

      await tester.tap(find.byTooltip('取消置顶'));
      await tester.pump();

      // The row leaves the list immediately, so no second tap can re-pin it
      // while the request (and the confirming reload) are in flight.
      expect(api.toggleCalls, 1);
      expect(find.text('Pinned'), findsNothing);
      expect(find.byTooltip('取消置顶'), findsNothing);

      api.pendingToggles.single.complete(false);
      await tester.pumpAndSettle();

      expect(api.toggleCalls, 1);
      expect(find.text('已取消置顶'), findsOneWidget);
      // The removal was accepted: the reload confirms the empty list.
      expect(api.callCount, 2);
      expect(find.text('暂无置顶消息'), findsOneWidget);
    },
  );

  testWidgets('unpin reports the server-confirmed pinned state', (
    tester,
  ) async {
    api.reset([
      () async => [_message(r'$pinned', '@alice:example.org', 'Pinned')],
      () async => [_message(r'$pinned', '@alice:example.org', 'Pinned')],
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ignoredUserIdsProvider.overrideWith((ref) async => <String>{}),
        ],
        child: const MaterialApp(
          home: PinnedMessagesPage(roomId: '!room:example.org'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Pinned'), findsOneWidget);

    await tester.tap(find.byTooltip('取消置顶'));
    await tester.pump();
    // A stale local list: the server had already dropped the pin elsewhere,
    // so the toggle re-pins it. The UI must say what the server decided and
    // restore the row via the reload.
    api.pendingToggles.single.complete(true);
    await tester.pumpAndSettle();

    expect(find.text('消息已置顶'), findsOneWidget);
    expect(find.text('已取消置顶'), findsNothing);
    expect(api.callCount, 2);
    expect(find.text('Pinned'), findsOneWidget);
  });

  testWidgets('a failed unpin restores the row and reconciles with the server', (
    tester,
  ) async {
    api.reset([
      () async => [_message(r'$pinned', '@alice:example.org', 'Pinned')],
    ]);
    // The reconciling reload after the failure returns the same list (the
    // server still pins the message).
    api._responses.add(() async => [
      _message(r'$pinned', '@alice:example.org', 'Pinned'),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ignoredUserIdsProvider.overrideWith((ref) async => <String>{}),
        ],
        child: const MaterialApp(
          home: PinnedMessagesPage(roomId: '!room:example.org'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('取消置顶'));
    await tester.pump();
    expect(find.text('Pinned'), findsNothing);

    api.pendingToggles.single.completeError(StateError('offline'));
    await tester.pumpAndSettle();

    // The server never accepted the removal: the row comes back, the error
    // is surfaced, and the follow-up reload reconciles the local list.
    expect(find.textContaining('取消置顶失败:'), findsOneWidget);
    expect(find.text('Pinned'), findsOneWidget);
    expect(api.callCount, 2);
  });

  testWidgets('a failed confirming reload keeps the unpin lock', (
    tester,
  ) async {
    api.reset([
      () async => [_message(r'$pinned', '@alice:example.org', 'Pinned')],
    ]);
    // The toggle succeeds (removal accepted) but the confirming reload fails.
    api._responses.add(() async => throw Exception('offline'));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ignoredUserIdsProvider.overrideWith((ref) async => <String>{}),
        ],
        child: const MaterialApp(
          home: PinnedMessagesPage(roomId: '!room:example.org'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('取消置顶'));
    await tester.pump();
    api.pendingToggles.single.complete(false);
    await tester.pumpAndSettle();

    // The removal is reflected (optimistic row already gone), the refresh
    // failure is surfaced, and no stale row offers a re-pinning tap.
    expect(find.text('已取消置顶'), findsOneWidget);
    expect(find.text('Pinned'), findsNothing);
    expect(find.text('刷新失败，当前显示上次结果'), findsOneWidget);
    expect(api.callCount, 2);
  });

  testWidgets('a stale confirming reload keeps the unpin lock until the row leaves', (
    tester,
  ) async {
    api.reset([
      () async => [_message(r'$pinned', '@alice:example.org', 'Pinned')],
    ]);
    // The confirming reload returns a stale snapshot that still contains the
    // message (offline store fallback, or a server read racing the write).
    api._responses.add(() async => [
      _message(r'$pinned', '@alice:example.org', 'Pinned'),
    ]);
    // The echo-driven reload finally drops the row.
    api._responses.add(() async => []);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ignoredUserIdsProvider.overrideWith((ref) async => <String>{}),
        ],
        child: const MaterialApp(
          home: PinnedMessagesPage(roomId: '!room:example.org'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('取消置顶'));
    await tester.pump();
    api.pendingToggles.single.complete(false);
    await tester.pumpAndSettle();

    // The stale snapshot restored the row, but the lock must survive it:
    // tapping again would re-pin the message.
    expect(find.text('Pinned'), findsOneWidget);
    final button = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.push_pin_outlined),
    );
    expect(button.onPressed, isNull);

    // The next reload (sync echo) reflects the removal and releases the lock.
    api.syncEvents.add(
      const rust.SyncEvent.pinnedMessagesChanged(roomId: '!room:example.org'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Pinned'), findsNothing);
    expect(find.text('暂无置顶消息'), findsOneWidget);
    expect(api.callCount, 3);
  });

  testWidgets('an unpin lock expires so a re-pinned row is not stuck', (
    tester,
  ) async {
    api.reset([
      () async => [_message(r'$pinned', '@alice:example.org', 'Pinned')],
    ]);
    // The confirming reload returns a stale snapshot that still contains the
    // message (e.g. another device re-pinned it); the row stays, locked.
    api._responses.add(() async => [
      _message(r'$pinned', '@alice:example.org', 'Pinned'),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ignoredUserIdsProvider.overrideWith((ref) async => <String>{}),
        ],
        child: const MaterialApp(
          home: PinnedMessagesPage(roomId: '!room:example.org'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('取消置顶'));
    await tester.pump();
    api.pendingToggles.single.complete(false);
    await tester.pumpAndSettle();

    expect(find.text('Pinned'), findsOneWidget);
    var button = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.push_pin_outlined),
    );
    expect(button.onPressed, isNull);

    // The lock times out (fake clock drives the expiry timer) and the button
    // becomes actionable again instead of staying disabled forever.
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();

    button = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.push_pin_outlined),
    );
    expect(button.onPressed, isNotNull);
  });
}
