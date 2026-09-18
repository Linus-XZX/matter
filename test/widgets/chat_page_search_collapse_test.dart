import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/chat_page.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart';

import '../helpers/neu_test_theme.dart';

void main() {
  ChatRoom room(String id, String name) => ChatRoom(
    id: id,
    name: name,
    lastMessage: '',
    lastMessageTime: '0',
    lastEventId: '',
    unreadCount: 0,
    isMarkedUnread: false,
    roomType: 'group',
    isEncrypted: false,
    isMuted: false,
    roomState: 'joined',
  );

  testWidgets('scrolling collapses the search entry into a header icon', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        chatRoomsProvider.overrideWith(
          (ref) async => [
            for (var i = 0; i < 20; i++) room('!room$i:example.org', 'Room $i'),
          ],
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: neuTestTheme(), home: const ChatPage()),
      ),
    );
    await tester.pump();

    // 静止时:搜索栏完整可见,头部搜索图标尚未出现。
    final searchEntry = find.byKey(const ValueKey('open-chat-search'));
    final headerIcon = find.byKey(const ValueKey('header-search-entry'));
    expect(searchEntry, findsOneWidget);
    expect(tester.getSize(searchEntry).height, greaterThan(0));
    expect(headerIcon, findsNothing);

    // 向上滚动一段距离:搜索栏随之渐隐,头部图标尚未出现。
    await tester.drag(find.byType(ListView), const Offset(0, -28));
    await tester.pump();

    expect(headerIcon, findsNothing);
    final entryOpacity = tester.widget<Opacity>(
      find.ancestor(of: searchEntry, matching: find.byType(Opacity)).first,
    );
    expect(entryOpacity.opacity, greaterThan(0));
    expect(entryOpacity.opacity, lessThan(1));

    // 继续滚动超过搜索栏高度:搜索栏完全滚出,头部搜索图标经时间动画显现。
    await tester.drag(find.byType(ListView), const Offset(0, -172));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(headerIcon, findsOneWidget);

    // 滚回顶部后恢复初始状态。
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(headerIcon, findsNothing);
    final restoredOpacity = tester.widget<Opacity>(
      find.ancestor(of: searchEntry, matching: find.byType(Opacity)).first,
    );
    expect(restoredOpacity.opacity, 1);
  });
}
