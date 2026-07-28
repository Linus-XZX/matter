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

  tearDownAll(RustLib.dispose);

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
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

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
}
