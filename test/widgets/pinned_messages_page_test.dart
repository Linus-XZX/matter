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

  void reset(List<Future<List<rust.ChatMessage>> Function()> responses) {
    _responses
      ..clear()
      ..addAll(responses);
    callCount = 0;
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
    api.subscribeHandler = (roomId) {
      calls.add('subscribe');
      return subscription.future;
    };
    api.unsubscribeHandler = (roomId) async {
      calls.add('unsubscribe');
    };
    api.reset([() async => []]);

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
}
