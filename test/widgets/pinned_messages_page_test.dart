import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/pinned_messages_page.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';

class _FakeRustApi implements RustLibApi {
  @override
  Future<List<rust.ChatMessage>> crateApiMatrixGetPinnedMessages({
    required String roomId,
  }) async {
    return [
      _message(r'$blocked', '@blocked:example.org', 'Blocked message'),
      _message(r'$visible', '@alice:example.org', 'Visible message'),
    ];
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
  setUpAll(() {
    RustLib.initMock(api: _FakeRustApi());
  });

  tearDownAll(RustLib.dispose);

  testWidgets('hides pinned messages from ignored users', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ignoredUserIdsProvider.overrideWith(
            (ref) async => {'@blocked:example.org'},
          ),
        ],
        child: const MaterialApp(
          home: PinnedMessagesPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Visible message'), findsOneWidget);
    expect(find.text('Blocked message'), findsNothing);
  });
}
