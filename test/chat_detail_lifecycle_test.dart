import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/chat_detail_page.dart';
import 'package:matter/pages/chat/image_message_bubble.dart';
import 'package:matter/pages/chat/message_insert_animation.dart';
import 'package:matter/pages/chat/send_flight.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeRustApi implements RustLibApi {
  int subscribeTypingCalls = 0;
  int unsubscribeTypingCalls = 0;
  int subscribeRoomCalls = 0;
  int unsubscribeRoomCalls = 0;
  int markRoomAsReadCalls = 0;
  int getMessagesBeforeCalls = 0;
  final messagesBeforeEventIds = <String>[];
  List<rust.ChatMessage> messagesBefore = const [];
  Object? messagesBeforeError;
  Completer<String>? pendingSend;
  List<rust.ChatRoom> chatRooms = const [];

  @override
  Future<List<rust.ChatRoom>> crateApiMatrixGetChatRooms({
    List<String>? ignoredUserIds,
    required bool authoritative,
  }) async {
    return chatRooms;
  }

  @override
  Future<String> crateApiMatrixSendMessage({
    required String roomId,
    required rust.FormattedMessageInput message,
  }) {
    return (pendingSend ??= Completer<String>()).future;
  }

  @override
  Future<void> crateApiMatrixSendTypingNotice({
    required String roomId,
    required bool typing,
  }) async {}
  String? activeTypingRoom;
  Completer<void>? typingUnsubscribeBarrier;

  @override
  Future<bool> crateApiMatrixIsRoomEncrypted({required String roomId}) async {
    return false;
  }

  @override
  Future<void> crateApiMatrixSubscribeTypingForRoom({
    required String roomId,
  }) async {
    subscribeTypingCalls++;
    activeTypingRoom = roomId;
  }

  @override
  Future<void> crateApiMatrixUnsubscribeTyping({required String roomId}) async {
    unsubscribeTypingCalls++;
    final barrier = typingUnsubscribeBarrier;
    if (barrier != null) await barrier.future;
    if (activeTypingRoom == roomId) activeTypingRoom = null;
  }

  @override
  Future<void> crateApiMatrixSubscribeRoomForReceipts({
    required String roomId,
  }) async {
    subscribeRoomCalls++;
  }

  @override
  Future<void> crateApiMatrixMarkRoomAsRead({required String roomId}) async {
    markRoomAsReadCalls++;
  }

  @override
  Future<List<rust.ChatMessage>> crateApiMatrixGetMessagesBefore({
    required String roomId,
    required String fromEventId,
    required int limit,
  }) async {
    getMessagesBeforeCalls++;
    messagesBeforeEventIds.add(fromEventId);
    if (messagesBeforeError case final error?) throw error;
    return messagesBefore;
  }

  @override
  Future<void> crateApiMatrixUnsubscribeRoomForReceipts({
    required String roomId,
  }) async {
    unsubscribeRoomCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
  }
}

rust.ChatMessage _message(String id) {
  return rust.ChatMessage(
    id: id,
    senderId: '@alice:example.org',
    senderName: 'Alice',
    content: 'hello',
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

rust.ChatMessage _ownMessage(
  String id, {
  required String content,
  required String timestamp,
  rust.MessageType msgType = rust.MessageType.text,
  String? imageUrl,
  int? imageWidth,
  int? imageHeight,
}) {
  return rust.ChatMessage(
    id: id,
    senderId: '',
    senderName: '我',
    content: content,
    mentionedUserIds: const [],
    mentionsRoom: false,
    timestamp: timestamp,
    isMe: true,
    msgType: msgType,
    imageUrl: imageUrl,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    isEdited: false,
    editHistory: const [],
    reactions: const [],
    readers: const [],
    totalMembers: 2,
  );
}

void main() {
  late _FakeRustApi rustApi;

  setUpAll(() {
    rustApi = _FakeRustApi();
    RustLib.initMock(api: rustApi);
  });

  tearDownAll(RustLib.dispose);

  setUp(() {
    rustApi.subscribeTypingCalls = 0;
    rustApi.unsubscribeTypingCalls = 0;
    rustApi.subscribeRoomCalls = 0;
    rustApi.unsubscribeRoomCalls = 0;
    rustApi.markRoomAsReadCalls = 0;
    rustApi.getMessagesBeforeCalls = 0;
    rustApi.messagesBeforeEventIds.clear();
    rustApi.messagesBefore = const [];
    rustApi.messagesBeforeError = null;
    rustApi.pendingSend = null;
    rustApi.chatRooms = const [];
    rustApi.activeTypingRoom = null;
    rustApi.typingUnsubscribeBarrier = null;
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('leaving a chat clears its active room without using ref', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: ChatDetailPage(roomId: '!room:example.org', roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();

    expect(container.read(currentRoomIdProvider), '!room:example.org');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SizedBox.shrink()),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(container.read(currentRoomIdProvider), isNull);
    expect(rustApi.unsubscribeTypingCalls, 1);
    expect(rustApi.subscribeRoomCalls, 1);
    expect(rustApi.unsubscribeRoomCalls, 1);
  });

  testWidgets('disposing an old chat does not clear its replacement room', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    Widget buildChat(String roomId) {
      return UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: ChatDetailPage(
            key: ValueKey(roomId),
            roomId: roomId,
            roomName: 'Room',
          ),
        ),
      );
    }

    await tester.pumpWidget(buildChat('!old:example.org'));
    await tester.pump();
    expect(
      rustApi.subscribeRoomCalls,
      1,
      reason: 'entering old room subscribes',
    );

    await tester.pumpWidget(buildChat('!new:example.org'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(container.read(currentRoomIdProvider), '!new:example.org');
    // old room disposed (unsubscribes), new room initialized (subscribes).
    expect(
      rustApi.subscribeRoomCalls,
      2,
      reason: 'entering new room subscribes',
    );
    expect(
      rustApi.unsubscribeRoomCalls,
      1,
      reason: 'old room unsubscribe on dispose',
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SizedBox.shrink(),
      ),
    );
    await tester.pump();
    expect(
      rustApi.unsubscribeRoomCalls,
      2,
      reason: 'new room unsubscribe on dispose',
    );
  });

  testWidgets('returning to a chat restores its room subscriptions', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorObservers: [chatRouteObserver],
          home: const ChatDetailPage(roomId: '!a:example.org', roomName: 'A'),
        ),
      ),
    );
    await tester.pump();

    final navigator = Navigator.of(tester.element(find.byType(ChatDetailPage)));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) =>
              const ChatDetailPage(roomId: '!b:example.org', roomName: 'B'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(container.read(currentRoomIdProvider), '!b:example.org');

    final unsubscribeBarrier = Completer<void>();
    rustApi.typingUnsubscribeBarrier = unsubscribeBarrier;
    navigator.pop();
    await tester.pumpAndSettle();

    expect(container.read(currentRoomIdProvider), '!a:example.org');
    expect(rustApi.subscribeTypingCalls, 3);
    expect(rustApi.subscribeRoomCalls, 3);

    unsubscribeBarrier.complete();
    await tester.pump();
    expect(rustApi.activeTypingRoom, '!a:example.org');
  });

  testWidgets('a covered chat stops being the active room until uncovered', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorObservers: [chatRouteObserver],
          home: const ChatDetailPage(
            roomId: '!room:example.org',
            roomName: 'Room',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(container.read(currentRoomIdProvider), '!room:example.org');

    final navigator = Navigator.of(tester.element(find.byType(ChatDetailPage)));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('cover')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // While covered, the chat must not be treated as the visible room:
    // incoming messages would otherwise be silently marked as read.
    expect(container.read(currentRoomIdProvider), isNull);
    final readCallsWhileCovered = rustApi.markRoomAsReadCalls;

    navigator.pop();
    await tester.pumpAndSettle();

    expect(container.read(currentRoomIdProvider), '!room:example.org');
    expect(rustApi.markRoomAsReadCalls, greaterThan(readCallsWhileCovered));
  });

  testWidgets('backgrounding deactivates the room until the app resumes', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: ChatDetailPage(roomId: '!room:example.org', roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    expect(container.read(currentRoomIdProvider), '!room:example.org');
    final readCallsBeforeBackground = rustApi.markRoomAsReadCalls;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    // In the background the room is no longer "being viewed", so background
    // sync must not auto-mark incoming messages as read.
    expect(container.read(currentRoomIdProvider), isNull);
    expect(rustApi.unsubscribeTypingCalls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(container.read(currentRoomIdProvider), '!room:example.org');
    expect(rustApi.markRoomAsReadCalls, greaterThan(readCallsBeforeBackground));
  });

  testWidgets('popping a cover while paused does not reactivate the room', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorObservers: [chatRouteObserver],
          home: const ChatDetailPage(
            roomId: '!room:example.org',
            roomName: 'Room',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(container.read(currentRoomIdProvider), '!room:example.org');

    final navigator = Navigator.of(tester.element(find.byType(ChatDetailPage)));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('cover')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(container.read(currentRoomIdProvider), isNull);

    // Pause the app, then pop the cover while still paused: the route
    // callback must not reactivate the room in the background.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    navigator.pop();
    await tester.pumpAndSettle();
    expect(container.read(currentRoomIdProvider), isNull);

    // Returning to the foreground reactivates it.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(container.read(currentRoomIdProvider), '!room:example.org');
  });

  testWidgets('popping a cover while inactive does not reactivate the room', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorObservers: [chatRouteObserver],
          home: const ChatDetailPage(
            roomId: '!room:example.org',
            roomName: 'Room',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(container.read(currentRoomIdProvider), '!room:example.org');

    final navigator = Navigator.of(tester.element(find.byType(ChatDetailPage)));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('cover')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(container.read(currentRoomIdProvider), isNull);

    // Pop the cover during a transient inactive window (e.g. notification
    // shade): the route callback must not reactivate the room.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    navigator.pop();
    await tester.pumpAndSettle();
    expect(container.read(currentRoomIdProvider), isNull);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(container.read(currentRoomIdProvider), '!room:example.org');
  });

  testWidgets('does not reactivate a chat route that is also being popped', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorObservers: [chatRouteObserver],
          home: const Scaffold(body: SizedBox(key: ValueKey('root-route'))),
        ),
      ),
    );
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const ChatDetailPage(
            roomId: '!leaving:example.org',
            roomName: 'Leaving',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final initialReadCalls = rustApi.markRoomAsReadCalls;

    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    navigator.pop();
    navigator.pop();
    await tester.pumpAndSettle();

    expect(find.byType(ChatDetailPage), findsNothing);
    expect(find.byKey(const ValueKey('root-route')), findsOneWidget);
    expect(rustApi.markRoomAsReadCalls, initialReadCalls);
  });

  testWidgets('waits for initial members before rendering cached messages', (
    tester,
  ) async {
    const roomId = '!members:example.org';
    final members = Completer<List<rust.Contact>>();
    final container = ProviderContainer(
      overrides: [
        roomMembersProvider(roomId).overrideWith((ref) => members.future),
      ],
    );
    addTearDown(container.dispose);
    container.read(messageCacheProvider(roomId).notifier).value = [
      _message(r'$members'),
    ];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('text-bubble:\$members')), findsNothing);

    members.complete(const []);
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('text-bubble:\$members')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('hides cached messages while the ignore list is unknown', (
    tester,
  ) async {
    const roomId = '!ignored-loading:example.org';
    final ignoredUsers = Completer<Set<String>>();
    final ownMessage = _ownMessage(r'$own', content: 'mine', timestamp: '2');
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) => ignoredUsers.future),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [
      _message(r'$ignored'),
      ownMessage,
    ];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();

    // While the ignore list is unknown, no messages are exposed unfiltered.
    expect(find.byKey(const ValueKey(r'text-bubble:$ignored')), findsNothing);
    expect(find.byKey(const ValueKey(r'text-bubble:$own')), findsNothing);

    ignoredUsers.complete(const {'@alice:example.org'});
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey(r'text-bubble:$ignored')), findsNothing);
    expect(find.byKey(const ValueKey(r'text-bubble:$own')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('keeps messages hidden when the ignore list fails to load', (
    tester,
  ) async {
    const roomId = '!ignored-failure:example.org';
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith(
          (ref) => Future<Set<String>>.error(StateError('offline')),
        ),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [
      _message(r'$ignored'),
    ];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey(r'text-bubble:$ignored')), findsNothing);
    expect(find.text('无法加载忽略列表，消息已隐藏'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('loads older history when ignored messages empty the window', (
    tester,
  ) async {
    const roomId = '!ignored-window:example.org';
    final older = _ownMessage(
      r'$older-visible',
      content: 'older',
      timestamp: '0',
    );
    rustApi.messagesBefore = [older];
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith(
          (ref) async => const {'@alice:example.org'},
        ),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [
      _message(r'$ignored-anchor'),
    ];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(rustApi.getMessagesBeforeCalls, greaterThanOrEqualTo(1));
    expect(rustApi.messagesBeforeEventIds.first, r'$ignored-anchor');
    expect(
      find.byKey(const ValueKey(r'text-bubble:$older-visible')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('removes newly ignored user messages from an open timeline', (
    tester,
  ) async {
    const roomId = '!ignored-live:example.org';
    var ignoredUsers = <String>{};
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => ignoredUsers),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [
      _message(r'$live-ignored'),
    ];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey(r'text-bubble:$live-ignored')),
      findsOneWidget,
    );

    ignoredUsers = {'@alice:example.org'};
    container.invalidate(ignoredUserIdsProvider);
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const ValueKey(r'text-bubble:$live-ignored')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('stops automatic older-message retries after a failure', (
    tester,
  ) async {
    const roomId = '!older-failure:example.org';
    rustApi.messagesBeforeError = StateError('offline');
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith(
          (ref) async => const {'@alice:example.org'},
        ),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [
      _message(r'$ignored-anchor'),
    ];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }

    expect(rustApi.getMessagesBeforeCalls, 1);
    expect(find.textContaining('加载更早消息失败'), findsOneWidget);
    expect(find.text('重试加载更早消息'), findsOneWidget);

    rustApi.messagesBeforeError = null;
    rustApi.messagesBefore = [
      _ownMessage(r'$manual-retry', content: 'recovered', timestamp: '0'),
    ];
    await tester.tap(find.text('重试加载更早消息'));
    await tester.pump();
    await tester.pump();

    expect(rustApi.getMessagesBeforeCalls, greaterThanOrEqualTo(2));
    expect(
      find.byKey(const ValueKey(r'text-bubble:$manual-retry')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('cached messages keep their first-frame vertical position', (
    tester,
  ) async {
    const roomId = '!cached:example.org';
    final container = ProviderContainer(
      overrides: [
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [
      _message(r'$cached'),
    ];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );

    final bubble = find.byKey(const ValueKey('text-bubble:\$cached'));
    expect(bubble, findsNothing);

    await tester.pump();

    expect(bubble, findsOneWidget);
    final firstTop = tester.getTopLeft(bubble).dy;

    await tester.pump(const Duration(milliseconds: 180));

    expect(tester.getTopLeft(bubble).dy, closeTo(firstTop, 0.1));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('appending a sticker keeps the previous sticker image state', (
    tester,
  ) async {
    const roomId = '!sticker-append:example.org';
    final firstSticker = _ownMessage(
      r'$first-sticker',
      content: 'first',
      timestamp: '100',
      msgType: rust.MessageType.sticker,
      imageUrl: 'https://example.org/first.png',
      imageWidth: 512,
      imageHeight: 512,
    );
    final secondSticker = _ownMessage(
      r'$second-sticker',
      content: 'second',
      timestamp: '101',
      msgType: rust.MessageType.sticker,
      imageUrl: 'https://example.org/second.png',
      imageWidth: 512,
      imageHeight: 512,
    );
    final container = ProviderContainer(
      overrides: [
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [
      firstSticker,
    ];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();

    final firstBubble = find.byKey(
      const ValueKey(r'image-bubble:$first-sticker'),
    );
    expect(firstBubble, findsOneWidget);
    final firstState = tester.state(firstBubble);

    container.read(messageCacheProvider(roomId).notifier).value = [
      firstSticker,
      secondSticker,
    ];
    await tester.pump();

    expect(tester.state(firstBubble), same(firstState));
    expect(find.byType(ImageMessageBubble), findsNWidgets(2));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('a rapid bottom send cancels flight and inserts smoothly', (
    tester,
  ) async {
    const roomId = '!animated-send:example.org';
    final oldMessage = _ownMessage(
      r'$old-message',
      content: 'old',
      timestamp: DateTime.now().millisecondsSinceEpoch.toString(),
    );
    final container = ProviderContainer(
      overrides: [
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [oldMessage];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();

    final oldBubble = find.byKey(const ValueKey(r'text-bubble:$old-message'));
    await tester.enterText(find.byType(TextField), 'new');
    await tester.pump(const Duration(milliseconds: 220));
    final initialTop = tester.getTopLeft(oldBubble).dy;
    final canceledFlight = registerSendFlight(
      '${localOutgoingPendingPrefix}already-flying',
      const SendFlightSpec(
        sourceRect: Rect.fromLTWH(20, 500, 80, 80),
        kind: SendFlightKind.sticker,
        child: SizedBox(),
      ),
    );
    expect(hasOngoingSendFlight, isTrue);

    final sendButton = tester.widget<IconButton>(
      find.descendant(
        of: find.byKey(const ValueKey('send_only')),
        matching: find.byType(IconButton),
      ),
    );
    sendButton.onPressed!();
    await tester.pump();

    expect(hasOngoingSendFlight, isFalse);
    await expectLater(canceledFlight, completes);
    expect(find.byType(MessageInsertAnimation), findsOneWidget);
    final lateralSlide = tester.widget<SlideTransition>(
      find.descendant(
        of: find.byType(MessageInsertAnimation),
        matching: find.byType(SlideTransition),
      ),
    );
    expect(lateralSlide.position.value.dx, greaterThan(0));
    expect(tester.getTopLeft(oldBubble).dy, closeTo(initialTop, 0.1));

    await tester.pump(const Duration(milliseconds: 120));
    final middleTop = tester.getTopLeft(oldBubble).dy;
    expect(middleTop, lessThan(initialTop));

    await tester.pump(const Duration(milliseconds: 160));
    expect(tester.getTopLeft(oldBubble).dy, lessThan(middleTop));

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('an open chat follows server-side room renames', (tester) async {
    rust.ChatRoom room(String name) => rust.ChatRoom(
      id: '!room:example.org',
      name: name,
      lastMessage: '',
      lastMessageTime: '',
      lastEventId: '',
      unreadCount: 0,
      isMarkedUnread: false,
      roomType: 'group',
      isEncrypted: false,
      isMuted: false,
      roomState: 'joined',
    );
    rustApi.chatRooms = [room('Old name')];

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sessionReadyProvider.notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: ChatDetailPage(
            roomId: '!room:example.org',
            roomName: 'Old name',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Old name'), findsWidgets);

    // Another client renamed the room; the next room-list snapshot carries it.
    rustApi.chatRooms = [room('New name')];
    container.invalidate(chatRoomsProvider);
    await tester.pump();
    await tester.pump();

    expect(find.text('Old name'), findsNothing);
    expect(find.text('New name'), findsWidgets);
  });
}
