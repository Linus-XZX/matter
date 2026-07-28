import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/app.dart';
import 'package:matter/pages/chat/chat_detail_page.dart';
import 'package:matter/pages/chat/desktop_room_details_panel.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeRustApi implements RustLibApi {
  int markRoomAsReadCalls = 0;

  @override
  Future<void> crateApiMatrixMarkRoomAsRead({required String roomId}) async {
    markRoomAsReadCalls++;
  }

  @override
  Future<bool> crateApiMatrixIsRoomEncrypted({required String roomId}) async {
    return false;
  }

  @override
  Future<void> crateApiMatrixSubscribeRoomForReceipts({
    required String roomId,
  }) async {}

  @override
  Future<void> crateApiMatrixSubscribeTypingForRoom({
    required String roomId,
  }) async {}

  @override
  Future<void> crateApiMatrixUnsubscribeRoomForReceipts({
    required String roomId,
  }) async {}

  @override
  Future<void> crateApiMatrixUnsubscribeTyping({
    required String roomId,
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
  }
}

rust.ChatRoom _room({
  required String id,
  required String name,
  required String roomType,
}) {
  return rust.ChatRoom(
    id: id,
    name: name,
    lastMessage: '',
    lastMessageTime: '0',
    unreadCount: 0,
    isMarkedUnread: false,
    roomType: roomType,
    isEncrypted: false,
    isMuted: false,
    roomState: 'joined',
  );
}

Future<void> _pumpApp(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: MatterApp()),
    ),
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
}

void main() {
  late _FakeRustApi rustApi;

  setUpAll(() {
    rustApi = _FakeRustApi();
    RustLib.initMock(api: rustApi);
  });

  tearDownAll(RustLib.dispose);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    rustApi.markRoomAsReadCalls = 0;
  });

  testWidgets('opens a nested space instead of its chat detail', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const rootId = '!root:example.org';
    const childId = '!child:example.org';
    final nestedRoom = _room(
      id: '!nested:example.org',
      name: 'Nested room',
      roomType: 'group',
    );
    final container = ProviderContainer(
      overrides: [
        chatRoomsProvider.overrideWith((ref) async => const []),
        spacesProvider.overrideWith(
          (ref) async => const [
            rust.Space(id: rootId, name: 'Root space', avatarUrl: null),
          ],
        ),
        spaceChildrenProvider(rootId).overrideWith(
          (ref) async => [
            _room(id: childId, name: 'Child space', roomType: 'space'),
          ],
        ),
        spaceChildrenProvider(
          childId,
        ).overrideWith((ref) async => [nestedRoom]),
      ],
    );
    addTearDown(container.dispose);

    await _pumpApp(tester, container);
    await tester.tap(find.byTooltip('Root space'));
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }

    final detail = tester.widget<ChatDetailPage>(find.byType(ChatDetailPage));
    expect(find.text('Child space'), findsOneWidget);
    expect(detail.roomId, nestedRoom.id);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hides the desktop details pane below its safe width', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final room = _room(
      id: '!room:example.org',
      name: 'Project room',
      roomType: 'dm',
    );
    final container = ProviderContainer(
      overrides: [
        chatRoomsProvider.overrideWith((ref) async => [room]),
        spacesProvider.overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);

    await _pumpApp(tester, container);
    await tester.tap(find.byTooltip('显示详情'));
    await tester.pump();
    expect(find.byType(DesktopRoomDetailsPanel), findsOneWidget);

    await tester.binding.setSurfaceSize(const Size(840, 800));
    await tester.pump();

    expect(find.byType(DesktopRoomDetailsPanel), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clears the selected desktop room after it is left', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final room = _room(
      id: '!room:example.org',
      name: 'Project room',
      roomType: 'dm',
    );
    final container = ProviderContainer(
      overrides: [
        chatRoomsProvider.overrideWith((ref) async => [room]),
        spacesProvider.overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);

    await _pumpApp(tester, container);
    final detail = tester.widget<ChatDetailPage>(find.byType(ChatDetailPage));

    detail.onRoomLeft!();
    await tester.pump();

    expect(find.byType(ChatDetailPage), findsNothing);
    expect(find.byType(DesktopRoomDetailsPanel), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('updates the selected desktop room metadata', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final room = _room(
      id: '!room:example.org',
      name: 'Project room',
      roomType: 'dm',
    );
    final container = ProviderContainer(
      overrides: [
        chatRoomsProvider.overrideWith((ref) async => [room]),
        spacesProvider.overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);

    await _pumpApp(tester, container);
    await tester.tap(find.byTooltip('显示详情'));
    await tester.pump();
    final detail = tester.widget<ChatDetailPage>(find.byType(ChatDetailPage));

    detail.onRoomDetailsChanged!(
      const rust.RoomDetails(
        id: '!room:example.org',
        name: 'Renamed room',
        hasExplicitName: true,
        avatarUrl: 'mxc://example.org/avatar',
      ),
    );
    await tester.pump();

    expect(
      tester.widget<ChatDetailPage>(find.byType(ChatDetailPage)).roomName,
      'Renamed room',
    );
    expect(
      tester
          .widget<DesktopRoomDetailsPanel>(find.byType(DesktopRoomDetailsPanel))
          .roomName,
      'Renamed room',
    );
    await tester.tap(find.text('Project room').first);
    await tester.pump();
    expect(
      tester.widget<ChatDetailPage>(find.byType(ChatDetailPage)).roomName,
      'Renamed room',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('syncs remote room metadata into the selected desktop room', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var rooms = [
      _room(id: '!room:example.org', name: 'Project room', roomType: 'dm'),
    ];
    final container = ProviderContainer(
      overrides: [
        chatRoomsProvider.overrideWith((ref) async => rooms),
        spacesProvider.overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);

    await _pumpApp(tester, container);
    await tester.tap(find.byTooltip('显示详情'));
    await tester.pump();

    rooms = [
      _room(id: '!room:example.org', name: 'Remote name', roomType: 'dm'),
    ];
    container.invalidate(chatRoomsProvider);
    await tester.pump();
    await tester.pump();

    expect(
      tester.widget<ChatDetailPage>(find.byType(ChatDetailPage)).roomName,
      'Remote name',
    );
    expect(
      tester
          .widget<DesktopRoomDetailsPanel>(find.byType(DesktopRoomDetailsPanel))
          .roomName,
      'Remote name',
    );
  });

  testWidgets('reselecting the current desktop room resumes read receipts', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final room = _room(
      id: '!room:example.org',
      name: 'Project room',
      roomType: 'dm',
    );
    final container = ProviderContainer(
      overrides: [
        chatRoomsProvider.overrideWith((ref) async => [room]),
        spacesProvider.overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);

    await _pumpApp(tester, container);
    final initialReadCalls = rustApi.markRoomAsReadCalls;
    container.read(roomAutoReadSuppressedProvider(room.id).notifier).value =
        true;

    await tester.tap(find.text('Project room').first);
    await tester.pump();

    expect(container.read(roomAutoReadSuppressedProvider(room.id)), isFalse);
    expect(rustApi.markRoomAsReadCalls, initialReadCalls + 1);
  });

  testWidgets('selects a room from the new account after switching accounts', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const aliceId = '@alice:example.org';
    const bobId = '@bob:example.org';
    final aliceRoom = _room(
      id: '!alice:example.org',
      name: 'Alice room',
      roomType: 'dm',
    );
    final bobRoom = _room(
      id: '!bob:example.org',
      name: 'Bob room',
      roomType: 'dm',
    );
    final container = ProviderContainer(
      overrides: [
        chatRoomsProvider.overrideWith(
          (ref) async => ref.watch(activeUserIdProvider) == bobId
              ? [bobRoom]
              : [aliceRoom],
        ),
        spacesProvider.overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = aliceId;

    await _pumpApp(tester, container);
    expect(
      tester.widget<ChatDetailPage>(find.byType(ChatDetailPage)).roomId,
      aliceRoom.id,
    );

    container.read(activeUserIdProvider.notifier).value = bobId;
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }

    expect(
      tester.widget<ChatDetailPage>(find.byType(ChatDetailPage)).roomId,
      bobRoom.id,
    );
    expect(tester.takeException(), isNull);
  });
}
