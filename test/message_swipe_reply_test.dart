import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/message_group.dart';
import 'package:matter/pages/chat/message_input.dart';
import 'package:matter/src/rust/api/matrix.dart';

const _roomId = '!room:example.org';

ChatMessage _message({required String id, required bool isMe}) => ChatMessage(
  id: id,
  senderId: isMe ? '@me:example.org' : '@alice:example.org',
  senderName: isMe ? '我' : 'Alice',
  content: '测试消息',
  mentionedUserIds: const [],
  mentionsRoom: false,
  timestamp: '100',
  isMe: isMe,
  msgType: MessageType.text,
  isEdited: false,
  editHistory: const [],
  reactions: const [],
  readers: const [],
  totalMembers: 2,
);

Widget _buildSubject({
  required ProviderContainer container,
  required ChatMessage message,
  VoidCallback? onReplyRequested,
  bool showAvatar = false,
}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: MessageGroupWidget(
          group: MessageGroup(
            senderId: message.senderId,
            senderName: message.senderName,
            isMe: message.isMe,
            messages: [message],
          ),
          roomId: _roomId,
          messageIndex: {message.id: message},
          showAvatar: showAvatar,
          onReplyRequested: onReplyRequested,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('left swipe past threshold starts a reply to another user', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final message = _message(id: r'$incoming', isMe: false);
    var replyRequests = 0;

    await tester.pumpWidget(
      _buildSubject(
        container: container,
        message: message,
        onReplyRequested: () => replyRequests++,
      ),
    );

    await tester.drag(
      find.byKey(const ValueKey(r'swipe-reply:$incoming')),
      const Offset(-70, 0),
    );
    await tester.pump();

    expect(container.read(replyingToProvider(_roomId)), message);
    expect(replyRequests, 1);
  });

  testWidgets('left swipe below threshold does not start a reply', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final message = _message(id: r'$short', isMe: false);

    await tester.pumpWidget(
      _buildSubject(container: container, message: message),
    );

    await tester.drag(
      find.byKey(const ValueKey(r'swipe-reply:$short')),
      const Offset(-30, 0),
    );
    await tester.pumpAndSettle();

    expect(container.read(replyingToProvider(_roomId)), isNull);
  });

  testWidgets('left swipe can start from empty space in the message row', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final message = _message(id: r'$full-row', isMe: false);

    await tester.pumpWidget(
      _buildSubject(container: container, message: message),
    );

    final swipeTarget = find.byKey(const ValueKey(r'swipe-reply:$full-row'));
    final targetRect = tester.getRect(swipeTarget);
    final bubbleRect = tester.getRect(
      find.byKey(const ValueKey(r'text-bubble:$full-row')),
    );
    final emptySpaceStart = Offset(targetRect.right - 12, targetRect.center.dy);

    expect(targetRect.width, greaterThan(bubbleRect.width + 100));
    expect(emptySpaceStart.dx, greaterThan(bubbleRect.right));

    final gesture = await tester.startGesture(emptySpaceStart);
    await gesture.moveBy(const Offset(-70, 0));
    await gesture.up();
    await tester.pump();

    expect(container.read(replyingToProvider(_roomId)), message);
  });

  testWidgets('own synced messages can also be swiped to reply', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final message = _message(id: r'$mine', isMe: true);

    await tester.pumpWidget(
      _buildSubject(container: container, message: message),
    );

    await tester.drag(
      find.byKey(const ValueKey(r'swipe-reply:$mine')),
      const Offset(-70, 0),
    );
    await tester.pump();

    expect(container.read(replyingToProvider(_roomId)), message);
  });

  testWidgets('reply icon animates in on the right while swiping', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final message = _message(id: r'$animated', isMe: false);

    await tester.pumpWidget(
      _buildSubject(container: container, message: message),
    );

    final swipeTarget = find.byKey(const ValueKey(r'swipe-reply:$animated'));
    final gesture = await tester.startGesture(tester.getCenter(swipeTarget));
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();

    final icon = find.descendant(
      of: swipeTarget,
      matching: find.byIcon(Icons.reply_rounded),
    );
    final opacity = tester.widget<Opacity>(
      find.ancestor(of: icon, matching: find.byType(Opacity)),
    );
    final scale = tester.widget<Transform>(
      find.ancestor(of: icon, matching: find.byType(Transform)).first,
    );
    final contentTransform = tester.widget<Transform>(
      find.byKey(const ValueKey('swipe-reply-content')),
    );

    expect(icon, findsOneWidget);
    expect(opacity.opacity, greaterThan(0));
    expect(scale.transform.storage[0], greaterThan(0.72));
    expect(contentTransform.transform.storage[12], lessThan(0));

    await gesture.up();
    await tester.pumpAndSettle();

    final settledTransform = tester.widget<Transform>(
      find.byKey(const ValueKey('swipe-reply-content')),
    );
    expect(settledTransform.transform.storage[12], 0);
  });

  testWidgets('avatar at its default position moves with the message', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final message = _message(id: r'$avatar-default', isMe: false);

    await tester.pumpWidget(
      _buildSubject(container: container, message: message, showAvatar: true),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(
        find.byKey(const ValueKey(r'swipe-reply:$avatar-default')),
      ),
    );
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();

    final dynamic avatarRender = tester.renderObject(
      find.byKey(const ValueKey('sticky-group-avatar-slot')),
    );
    expect(avatarRender.debugIsSticky, isFalse);
    expect(avatarRender.debugHorizontalPaintOffset, closeTo(-40, 0.1));

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('sticky avatar stays fixed below the swiped message', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    final viewportKey = GlobalKey();
    final first = _message(id: r'$sticky-first', isMe: false);
    final last = _message(id: r'$sticky-last', isMe: false);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 120,
              child: SingleChildScrollView(
                key: viewportKey,
                controller: scrollController,
                child: MessageGroupWidget(
                  group: MessageGroup(
                    senderId: first.senderId,
                    senderName: first.senderName,
                    isMe: false,
                    messages: [first, last],
                  ),
                  roomId: _roomId,
                  messageIndex: {first.id: first, last.id: last},
                  showAvatar: true,
                  scrollController: scrollController,
                  scrollViewportKey: viewportKey,
                  stickyBottomInset: 100,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey(r'swipe-reply:$sticky-last'))),
    );
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();

    final dynamic avatarRender = tester.renderObject(
      find.byKey(const ValueKey('sticky-group-avatar-slot')),
    );
    final contentTransform = tester.widget<Transform>(
      find.byKey(const ValueKey('swipe-reply-content')).last,
    );
    expect(avatarRender.debugIsSticky, isTrue);
    expect(avatarRender.debugHorizontalPaintOffset, 0);
    expect(contentTransform.transform.storage[12], lessThan(0));

    final stack = tester.widget<Stack>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('sticky-group-avatar-slot')),
            matching: find.byType(Stack),
          )
          .first,
    );
    expect(
      (stack.children.last as Padding).key,
      const ValueKey('sticky-group-messages-layer'),
    );

    await gesture.up();
    await tester.pumpAndSettle();
  });
}
