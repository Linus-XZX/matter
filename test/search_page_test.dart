import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/search_bar.dart';
import 'package:matter/pages/chat/search_page.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;

rust.ChatRoom _room({
  required String id,
  required String name,
  String roomState = 'joined',
}) => rust.ChatRoom(
  id: id,
  name: name,
  lastMessage: '',
  lastMessageTime: '',
  lastEventId: '',
  unreadCount: 0,
  isMarkedUnread: false,
  roomType: 'group',
  isEncrypted: true,
  isMuted: false,
  roomState: roomState,
);

const _cjkResult = rust.MessageSearchResult(
  roomId: '!room:example.org',
  roomName: '产品讨论',
  eventId: r'$event',
  senderId: '@alice:example.org',
  senderName: 'Alice',
  body: '今晚八点开会',
  timestamp: '1710000000000',
  isDm: false,
  isEdited: false,
);

void main() {
  testWidgets('chat search bar opens the global search page', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: Scaffold(body: ChatSearchBar())),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('open-chat-search')));
    await tester.pumpAndSettle();

    expect(find.byType(ChatSearchPage), findsOneWidget);
    expect(find.text('消息'), findsOneWidget);
    expect(find.text('聊天'), findsOneWidget);
  });

  test('room filtering supports CJK names and excludes left rooms', () {
    final rooms = [
      _room(id: '!one:example.org', name: '产品讨论'),
      _room(id: '!two:example.org', name: 'General'),
      _room(id: '!left:example.org', name: '产品旧群', roomState: 'left'),
    ];

    expect(filterRoomsForSearch(rooms, '产品').map((room) => room.id), [
      '!one:example.org',
    ]);
    expect(filterRoomsForSearch(rooms, '!TWO').single.name, 'General');
  });

  testWidgets('room message search returns a CJK result event id', (
    tester,
  ) async {
    String? selectedEventId;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          messageSearchProvider.overrideWith(
            (ref, request) async => const rust.MessageSearchPage(
              results: [_cjkResult],
              hasMore: false,
            ),
          ),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  selectedEventId = await Navigator.of(context).push<String>(
                    MaterialPageRoute(
                      builder: (_) =>
                          const ChatSearchPage(roomId: '!room:example.org'),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('chat-search-field')),
      '八点',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(find.text('今晚八点开会', findRichText: true), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey(r'message-search-result-$event')),
    );
    await tester.pumpAndSettle();

    expect(selectedEventId, r'$event');
  });

  testWidgets('message search requests more results without losing the query', (
    tester,
  ) async {
    final requestedLimits = <int>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          messageSearchProvider.overrideWith((ref, request) async {
            requestedLimits.add(request.limit);
            return const rust.MessageSearchPage(
              results: [_cjkResult],
              hasMore: true,
            );
          }),
        ],
        child: const MaterialApp(
          home: ChatSearchPage(roomId: '!room:example.org'),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('chat-search-field')),
      '开会',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(requestedLimits, contains(30));

    await tester.tap(find.text('加载更多'));
    await tester.pump();
    expect(requestedLimits, contains(60));
  });
}
