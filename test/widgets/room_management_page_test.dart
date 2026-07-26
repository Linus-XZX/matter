import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/room_management_page.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';

class _FakeRustApi implements RustLibApi {
  bool failSupplementalLoads = true;

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
}
