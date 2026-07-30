import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/room_metadata_patch.dart';
import 'package:matter/pages/chat/room_management_page.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/providers/mutable_state.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The knock-requests provider is gated on an active session; tests pump the
/// management page without one, so force the session ready.
final _sessionReadyOverride = sessionReadyProvider.overrideWith(
  () => MutableState(true),
);

class _FakeRustApi implements RustLibApi {
  bool failSupplementalLoads = true;
  Completer<void>? pendingDetailsUpdate;
  List<rust.KnockRequest> knockRequests = const [];
  int detailsLoadCalls = 0;
  int membersLoadCalls = 0;
  int approveKnockCalls = 0;
  int rejectKnockCalls = 0;
  int markUnreadCalls = 0;
  int setMutedCalls = 0;
  int setIgnoredCalls = 0;
  Completer<void>? pendingMutedUpdate;
  Completer<void>? pendingApproveKnock;
  Completer<List<String>>? pendingSetIgnored;
  String? nameUpdateError;
  String? topicUpdateError;
  String? updatedName;
  String? updatedTopic;

  @override
  Future<rust.RoomDetails> crateApiMatrixGetRoomDetails({
    required String roomId,
  }) async {
    detailsLoadCalls++;
    return rust.RoomDetails(
      id: roomId,
      name: 'Project room',
      hasExplicitName: true,
      topic: 'Topic',
      nameEventId: r'$name-0',
    );
  }

  @override
  Future<bool> crateApiMatrixIsRoomMuted({required String roomId}) async {
    if (failSupplementalLoads) throw StateError('muted unavailable');
    return true;
  }

  @override
  Future<void> crateApiMatrixSetRoomMuted({
    required String roomId,
    required bool muted,
  }) {
    setMutedCalls++;
    return pendingMutedUpdate?.future ?? Future.value();
  }

  @override
  Future<List<rust.Contact>> crateApiMatrixGetRoomMembers({
    required String roomId,
  }) async {
    membersLoadCalls++;
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
    return knockRequests;
  }

  @override
  Future<rust.IgnoredUsers> crateApiMatrixGetIgnoredUsers() async {
    if (failSupplementalLoads) throw StateError('ignored unavailable');
    return rust.IgnoredUsers(
      userIds: const ['@blocked:example.org'],
      fromServer: true,
    );
  }

  @override
  Future<List<String>> crateApiMatrixSetUserIgnored({
    required String userId,
    required bool ignored,
  }) {
    setIgnoredCalls++;
    return pendingSetIgnored?.future ?? Future.value(const []);
  }

  @override
  Future<rust.RoomDetailsUpdate> crateApiMatrixUpdateRoomDetails({
    required String roomId,
    required String name,
    required bool updateName,
    String? topic,
  }) async {
    updatedName = name;
    updatedTopic = topic;
    await pendingDetailsUpdate?.future;
    return rust.RoomDetailsUpdate(
      nameEventId: updateName && nameUpdateError == null ? r'$name-1' : null,
      nameError: nameUpdateError,
      topicError: topicUpdateError,
    );
  }

  @override
  Future<void> crateApiMatrixApproveRoomKnock({
    required String roomId,
    required String userId,
  }) async {
    approveKnockCalls++;
    await pendingApproveKnock?.future;
  }

  @override
  Future<void> crateApiMatrixRejectRoomKnock({
    required String roomId,
    required String userId,
  }) async {
    rejectKnockCalls++;
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
    rustApi.knockRequests = const [];
    rustApi.detailsLoadCalls = 0;
    rustApi.membersLoadCalls = 0;
    rustApi.approveKnockCalls = 0;
    rustApi.rejectKnockCalls = 0;
    rustApi.markUnreadCalls = 0;
    rustApi.setMutedCalls = 0;
    rustApi.setIgnoredCalls = 0;
    rustApi.pendingMutedUpdate = null;
    rustApi.pendingApproveKnock = null;
    rustApi.pendingSetIgnored = null;
    rustApi.nameUpdateError = null;
    rustApi.topicUpdateError = null;
    rustApi.updatedName = null;
    rustApi.updatedTopic = null;
  });

  testWidgets('shows partial load failures instead of empty room data', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
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
      ProviderScope(
        overrides: [_sessionReadyOverride],
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
      ProviderScope(
        overrides: [_sessionReadyOverride],
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

  testWidgets(
    'ignoring a user writes through even if the page closes mid-request',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final ignore = Completer<List<String>>();
      rustApi.failSupplementalLoads = false;
      rustApi.pendingSetIgnored = ignore;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            _sessionReadyOverride,
            activeUserIdProvider.overrideWith(
              () => MutableState<String?>('@carol:example.org'),
            ),
          ],
          child: MaterialApp(
            home: RoomManagementPage(
              roomId: '!room:example.org',
              roomName: 'Project room',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('忽略用户'));
      await tester.pump();
      expect(rustApi.setIgnoredCalls, 1);

      // The page is popped while the server request is still in flight; the
      // write-through must still land in the persisted snapshot, otherwise
      // the sender's cached messages stay visible. The response carries the
      // complete post-write list (the server already held @blocked), so the
      // first-ever write-through must not drop other ignored users.
      await tester.pumpWidget(const SizedBox.shrink());
      ignore.complete(const ['@blocked:example.org', '@alice:example.org']);
      await tester.pump();
      await tester.pump();

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getStringList('ignored_users_v1_@carol:example.org'),
        containsAll(['@blocked:example.org', '@alice:example.org']),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('keeps saved room details instead of reloading stale cache', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    RoomNamePatch? changedName;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
            onRoomDetailsChanged: (patch) {
              if (patch is RoomNamePatch) changedName = patch;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Renamed room');
    await tester.enterText(fields.at(1), 'Updated topic');
    await tester.tap(find.byTooltip('保存房间信息'));
    await tester.pumpAndSettle();

    expect(rustApi.detailsLoadCalls, 1);
    expect(rustApi.updatedName, 'Renamed room');
    expect(rustApi.updatedTopic, 'Updated topic');
    expect(
      tester.widget<TextField>(fields.at(0)).controller!.text,
      'Renamed room',
    );
    expect(
      tester.widget<TextField>(fields.at(1)).controller!.text,
      'Updated topic',
    );
    expect(changedName?.name, 'Renamed room');
  });

  testWidgets('keeps a successful rename when the topic update fails', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    rustApi.topicUpdateError = 'topic unavailable';
    RoomNamePatch? changedName;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
            onRoomDetailsChanged: (patch) {
              if (patch is RoomNamePatch) changedName = patch;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Renamed room');
    await tester.enterText(fields.at(1), 'Updated topic');
    await tester.tap(find.byTooltip('保存房间信息'));
    await tester.pumpAndSettle();

    expect(changedName?.name, 'Renamed room');
    expect(changedName?.nameEventId, r'$name-1');
    expect(find.textContaining('主题更新失败'), findsOneWidget);
  });

  testWidgets('saving only the topic preserves remote room metadata', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    RoomMetadataPatch? changedPatch;
    var outerName = 'Remote name';
    String? outerAvatarUrl = 'mxc://example.org/remote-avatar';

    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
            onRoomDetailsChanged: (patch) {
              changedPatch = patch;
              switch (patch) {
                case RoomNamePatch():
                  outerName = patch.name;
                  break;
                case RoomAvatarPatch():
                  outerAvatarUrl = patch.avatarUrl;
                  break;
              }
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(1), 'Updated topic');
    await tester.tap(find.byTooltip('保存房间信息'));
    await tester.pumpAndSettle();

    expect(changedPatch, isNull);
    expect(outerName, 'Remote name');
    expect(outerAvatarUrl, 'mxc://example.org/remote-avatar');
  });

  testWidgets('removes an approved knock and refreshes room members', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    rustApi.knockRequests = const [
      rust.KnockRequest(userId: '@bob:example.org', displayName: 'Bob'),
    ];

    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Bob'), findsOneWidget);
    await tester.tap(find.byTooltip('批准'));
    await tester.pumpAndSettle();

    expect(rustApi.approveKnockCalls, 1);
    expect(rustApi.membersLoadCalls, 2);
    expect(find.text('Bob'), findsNothing);
  });

  testWidgets('disables both knock actions while one is in flight', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    rustApi.knockRequests = const [
      rust.KnockRequest(userId: '@bob:example.org', displayName: 'Bob'),
    ];
    final pendingApprove = Completer<void>();
    rustApi.pendingApproveKnock = pendingApprove;

    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: const MaterialApp(
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('批准'));
    await tester.pump();

    IconButton actionButton(String tooltip) => tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip(tooltip),
        matching: find.byType(IconButton),
      ),
    );
    expect(actionButton('批准').onPressed, isNull);
    expect(actionButton('拒绝').onPressed, isNull);
    await tester.tap(find.byTooltip('拒绝'));
    expect(rustApi.approveKnockCalls, 1);
    expect(rustApi.rejectKnockCalls, 0);

    pendingApprove.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('a re-knock becomes visible again after the server echo', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    rustApi.knockRequests = const [
      rust.KnockRequest(userId: '@bob:example.org', displayName: 'Bob'),
    ];

    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: const MaterialApp(
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Bob'), findsOneWidget);
    await tester.tap(find.byTooltip('拒绝'));
    await tester.pumpAndSettle();

    expect(rustApi.rejectKnockCalls, 1);
    // Optimistically hidden until the server echo removes the membership.
    expect(find.text('Bob'), findsNothing);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(RoomManagementPage)),
    );

    // Server echo: the rejected knock is gone from the membership list.
    rustApi.knockRequests = const [];
    container.invalidate(roomKnockRequestsProvider('!room:example.org'));
    await tester.pumpAndSettle();

    // The same user knocks again; the new request must become visible.
    rustApi.knockRequests = const [
      rust.KnockRequest(userId: '@bob:example.org', displayName: 'Bob'),
    ];
    container.invalidate(roomKnockRequestsProvider('!room:example.org'));
    await tester.pumpAndSettle();

    expect(find.text('Bob'), findsOneWidget);
  });

  testWidgets('disables the mute switch while a mute update is in flight', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    final pending = Completer<void>();
    rustApi.pendingMutedUpdate = pending;

    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: const MaterialApp(
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final muteSwitch = find.byType(SwitchListTile);
    expect(muteSwitch, findsOneWidget);

    await tester.tap(muteSwitch);
    await tester.pump();
    expect(rustApi.setMutedCalls, 1);

    // While the request is in flight the switch is disabled: rapid toggles
    // must not fire competing push-rule updates.
    await tester.tap(muteSwitch);
    await tester.pump();
    expect(rustApi.setMutedCalls, 1);

    pending.complete();
    await tester.pumpAndSettle();
    await tester.tap(muteSwitch);
    await tester.pump();
    expect(rustApi.setMutedCalls, 2);
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
        overrides: [_sessionReadyOverride],
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

  testWidgets('closing a nested chat preserves its parent route', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;

    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          home: Builder(
            builder: (rootContext) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(rootContext).push(
                  MaterialPageRoute<void>(
                    builder: (spaceContext) => Scaffold(
                      body: TextButton(
                        onPressed: () => Navigator.of(spaceContext).push(
                          MaterialPageRoute<void>(
                            builder: (chatContext) => Scaffold(
                              body: TextButton(
                                onPressed: () => Navigator.of(chatContext).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => const RoomManagementPage(
                                      roomId: '!room:example.org',
                                      roomName: 'Project room',
                                    ),
                                  ),
                                ),
                                child: const Text('打开管理'),
                              ),
                            ),
                          ),
                        ),
                        child: const Text('打开聊天'),
                      ),
                    ),
                  ),
                ),
                child: const Text('打开空间'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开空间'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开聊天'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开管理'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('标记为未读'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('标记为未读'));
    await tester.pumpAndSettle();

    expect(find.text('打开聊天'), findsOneWidget);
    expect(find.text('打开空间'), findsNothing);
    expect(find.byType(RoomManagementPage), findsNothing);
  });
}
