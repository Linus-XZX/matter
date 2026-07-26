import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/room_management_page.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';

class _FakeRustApi implements RustLibApi {
  bool failSupplementalLoads = true;
  Completer<void>? pendingDetailsUpdate;
  int markUnreadCalls = 0;

  @override
  Future<rust.RoomDetails> crateApiMatrixGetRoomDetails({
    required String roomId,
  }) async {
    return rust.RoomDetails(
      id: roomId,
      name: 'Project room',
      hasExplicitName: true,
      topic: 'Topic',
    );
  }

  @override
  Future<bool> crateApiMatrixIsRoomMuted({required String roomId}) async {
    if (failSupplementalLoads) throw StateError('muted unavailable');
    return true;
  }

  @override
  Future<List<rust.Contact>> crateApiMatrixGetRoomMembers({
    required String roomId,
  }) async {
    if (failSupplementalLoads) throw StateError('members unavailable');
    return const [
      rust.Contact(id: '@alice:example.org', name: 'Alice', status: 'online'),
    ];
  }

  @override
  Future<List<rust.KnockRequest>> crateApiMatrixGetRoomKnockRequests({
    required String roomId,
  }) async {
    if (failSupplementalLoads) throw StateError('knocks unavailable');
    return const [];
  }

  @override
  Future<List<String>> crateApiMatrixGetIgnoredUsers() async {
    if (failSupplementalLoads) throw StateError('ignored unavailable');
    return const ['@blocked:example.org'];
  }

  @override
  Future<void> crateApiMatrixUpdateRoomDetails({
    required String roomId,
    required String name,
    required bool updateName,
    String? topic,
  }) {
    return pendingDetailsUpdate?.future ?? Future.value();
  }

  @override
  Future<void> crateApiMatrixMarkRoomUnread({required String roomId}) async {
    markUnreadCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
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
    rustApi.failSupplementalLoads = true;
    rustApi.pendingDetailsUpdate = null;
    rustApi.markUnreadCalls = 0;
  });

  testWidgets('shows partial load failures instead of empty room data', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('无法加载成员'), findsOneWidget);
    expect(find.text('无法加载加入请求'), findsOneWidget);
    expect(find.text('无法加载通知设置'), findsOneWidget);
    expect(find.text('无法加载已忽略用户'), findsOneWidget);
    expect(find.text('成员 0'), findsNothing);
    expect(find.text('已忽略用户 (0)'), findsNothing);
  });

  testWidgets('retries a failed supplemental section independently', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    rustApi.failSupplementalLoads = false;

    final memberErrorTile = find.ancestor(
      of: find.text('无法加载成员'),
      matching: find.byType(ListTile),
    );
    await tester.tap(
      find.descendant(of: memberErrorTile, matching: find.byTooltip('重试')),
    );
    await tester.pumpAndSettle();

    expect(find.text('成员 1'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('无法加载加入请求'), findsOneWidget);
  });

  testWidgets('finishing a save after leaving does not update disposed state', (
    tester,
  ) async {
    final update = Completer<void>();
    rustApi.pendingDetailsUpdate = update;

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('保存房间信息'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    update.complete();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('marking the current room unread closes its chat view', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    var roomClosed = false;

    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => RoomManagementPage(
                      roomId: '!room:example.org',
                      roomName: 'Project room',
                      onRoomClosed: () => roomClosed = true,
                    ),
                  ),
                ),
                child: const Text('打开房间'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开房间'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('标记为未读'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('标记为未读'));
    await tester.pumpAndSettle();

    expect(rustApi.markUnreadCalls, 1);
    expect(roomClosed, isTrue);
    expect(find.byType(RoomManagementPage), findsNothing);
    expect(find.text('打开房间'), findsOneWidget);
  });
}
