import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsNode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/message_group.dart';
import 'package:matter/pages/chat/message_reader_page.dart';
import 'package:matter/src/rust/api/matrix.dart';

void main() {
  Widget harness(Widget child) => MaterialApp(
    home: Scaffold(body: SizedBox(width: 300, child: child)),
  );

  CollapsibleMessageContent collapsible({
    required Widget child,
    Widget? overflowChild,
    Widget? overflowMetadata,
    Object? contentKey,
    VoidCallback? onExpand,
  }) => CollapsibleMessageContent(
    maxCollapsedHeight: 320,
    accentColor: Colors.cyan,
    backgroundColor: Colors.white,
    contentKey: contentKey,
    onExpand: onExpand ?? () {},
    overflowChild: overflowChild,
    overflowMetadata: overflowMetadata,
    child: child,
  );

  group('CollapsibleMessageContent', () {
    testWidgets('short content shows no expand button', (tester) async {
      await tester.pumpWidget(
        harness(collapsible(child: const Text('short message'))),
      );
      await tester.pumpAndSettle();

      expect(find.text('展开阅读'), findsNothing);
    });

    testWidgets(
      'tall content clips on the first frame with zero height drift',
      (tester) async {
        var expanded = false;
        await tester.pumpWidget(
          harness(
            collapsible(
              onExpand: () => expanded = true,
              child: Text(List.generate(100, (i) => 'line $i').join('\n')),
            ),
          ),
        );
        // Clipping happens within the first layout pass — no full-height
        // flash before the collapse.
        final firstFrameHeight = tester
            .getSize(find.byType(CollapsibleMessageContent))
            .height;
        expect(firstFrameHeight, lessThanOrEqualTo(320));

        await tester.pumpAndSettle();
        expect(find.text('展开阅读'), findsOneWidget);
        // The overlay row sits inside the fixed clip height, so the widget
        // never grows after the first frame — no timeline jumps.
        expect(
          tester.getSize(find.byType(CollapsibleMessageContent)).height,
          firstFrameHeight,
        );

        await tester.tap(find.text('展开阅读'));
        expect(expanded, isTrue);
      },
    );

    testWidgets('metadata is mounted exactly once while collapsed', (
      tester,
    ) async {
      final lines = List.generate(100, (i) => 'line $i').join('\n');
      await tester.pumpWidget(
        harness(
          collapsible(
            overflowChild: Text(lines),
            overflowMetadata: const Text('meta'),
            child: Text('$lines\nmeta'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('展开阅读'), findsOneWidget);
      // The clipped content is the metadata-less variant, so only the
      // overlay copy of the metadata remains — never a half-clipped
      // duplicate.
      expect(find.text('meta'), findsOneWidget);
    });

    testWidgets('borderline heights do not oscillate or drift', (tester) async {
      // 330px content with a 310px metadata-less variant against a 320px
      // threshold: the overflow state latches and the clip height pins, so
      // the collapsed state is stable instead of flip-flopping between the
      // two contents or shrinking after the first frame.
      await tester.pumpWidget(
        harness(
          collapsible(
            overflowChild: const SizedBox(height: 310, width: 300),
            overflowMetadata: const Text('meta'),
            child: const SizedBox(height: 330, width: 300),
          ),
        ),
      );
      final firstFrameHeight = tester
          .getSize(find.byType(CollapsibleMessageContent))
          .height;
      expect(firstFrameHeight, 320);

      await tester.pumpAndSettle();
      expect(find.text('展开阅读'), findsOneWidget);
      expect(
        tester.getSize(find.byType(CollapsibleMessageContent)).height,
        firstFrameHeight,
      );

      for (var i = 0; i < 5; i++) {
        await tester.pump();
        expect(find.text('展开阅读'), findsOneWidget);
        expect(
          tester.getSize(find.byType(CollapsibleMessageContent)).height,
          firstFrameHeight,
        );
      }
    });

    testWidgets('overlay participates in width for narrow content', (
      tester,
    ) async {
      // Long but narrow content: the bubble is only as wide as the text,
      // and the overlay row must not be clipped horizontally.
      await tester.pumpWidget(
        harness(
          collapsible(
            overflowMetadata: const Text('10:24'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: List.generate(60, (i) => const Text('x')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('展开阅读'), findsOneWidget);
      expect(find.text('10:24'), findsOneWidget);
    });

    testWidgets('overlay wraps instead of overflowing at large text scale', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              textScaler: TextScaler.linear(3),
              size: Size(300, 800),
            ),
            child: Scaffold(
              body: SizedBox(
                width: 300,
                child: collapsible(
                  overflowMetadata: const Text('10:24'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(30, (i) => const Text('x')),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('展开阅读'), findsOneWidget);
    });

    testWidgets('collapse re-evaluates when the layout width changes', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final longLine = 'word ' * 40;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              child: collapsible(child: Text(longLine * 10)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('展开阅读'), findsOneWidget);

      // Widening the window lets the same content fit: the collapsed state
      // must be released.
      tester.view.physicalSize = const Size(2000, 800);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 2000,
              child: collapsible(child: Text(longLine * 10)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('展开阅读'), findsNothing);
    });

    testWidgets('collapse releases when the available width grows without '
        'a window resize', (tester) async {
      // Same window size throughout: only the bubble's constraints change,
      // like a details sidebar closing and widening the chat area.
      final longLine = 'word ' * 40;
      Widget wrap(double width) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: width,
            child: collapsible(child: Text(longLine * 3)),
          ),
        ),
      );

      await tester.pumpWidget(wrap(300));
      await tester.pumpAndSettle();
      expect(find.text('展开阅读'), findsOneWidget);

      await tester.pumpWidget(wrap(700));
      await tester.pumpAndSettle();
      expect(find.text('展开阅读'), findsNothing);
    });

    testWidgets('clipped-away content stays out of the semantics tree', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        harness(
          collapsible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ...List.generate(60, (i) => Text('line $i')),
                Semantics(
                  label: 'hidden action',
                  button: true,
                  child: const SizedBox(width: 100, height: 40),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('展开阅读'), findsOneWidget);
      // Walk the compiled semantics tree: the fully clipped action must be
      // gone entirely (its rect is clipped to empty, which drops the node),
      // while visible content stays reachable.
      final labels = <String>[];
      bool collectLabels(SemanticsNode node) {
        labels.add(node.label);
        node.visitChildren(collectLabels);
        return true;
      }

      final renderView = tester.binding.renderViews.first;
      collectLabels(renderView.owner!.semanticsOwner!.rootSemanticsNode!);
      expect(labels, isNot(contains('hidden action')));
      expect(labels, contains('line 0'));
      handle.dispose();
    });

    testWidgets('overlay metadata is not shown for short content', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          collapsible(
            overflowMetadata: const Text('meta'),
            child: const Text('short message'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('展开阅读'), findsNothing);
      expect(find.text('meta'), findsNothing);
    });

    testWidgets('collapse state re-evaluates when the content key changes', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          collapsible(
            contentKey: 'v1',
            child: Text(List.generate(100, (i) => 'line $i').join('\n')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('展开阅读'), findsOneWidget);

      await tester.pumpWidget(
        harness(collapsible(contentKey: 'v2', child: const Text('short now'))),
      );
      await tester.pumpAndSettle();
      expect(find.text('展开阅读'), findsNothing);
    });
  });

  group('full-screen reader entry', () {
    const message = ChatMessage(
      id: r'$read',
      senderId: '@bob:example.org',
      senderName: 'Bob',
      content: '**Hello** markdown',
      formattedBody: '<p><strong>Hello</strong> markdown</p>',
      mentionedUserIds: [],
      mentionsRoom: false,
      timestamp: '100',
      isMe: false,
      msgType: MessageType.text,
      isEdited: false,
      editHistory: [],
      reactions: [],
      readers: [],
      totalMembers: 2,
    );

    Widget app() => ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: MessageGroupWidget(
            group: MessageGroup(
              senderId: message.senderId,
              senderName: message.senderName,
              isMe: false,
              messages: const [message],
            ),
            roomId: '!room:example.org',
            messageIndex: const {r'$read': message},
            membersById: const {},
            showAvatar: false,
          ),
        ),
      ),
    );

    testWidgets('long-press menu opens the full-screen reader', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await tester.longPress(find.byKey(const ValueKey('text-bubble:\$read')));
      await tester.pumpAndSettle();

      expect(find.text('全屏阅读'), findsOneWidget);
      await tester.tap(find.text('全屏阅读'));
      await tester.pumpAndSettle();

      expect(find.byType(MessageReaderPage), findsOneWidget);
      expect(find.text('Hello markdown', findRichText: true), findsOneWidget);
    });

    testWidgets('reader is not offered for plain-text messages', (
      tester,
    ) async {
      const plain = ChatMessage(
        id: r'$plain',
        senderId: '@bob:example.org',
        senderName: 'Bob',
        content: 'just plain text',
        formattedBody: null,
        mentionedUserIds: [],
        mentionsRoom: false,
        timestamp: '100',
        isMe: false,
        msgType: MessageType.text,
        isEdited: false,
        editHistory: [],
        reactions: [],
        readers: [],
        totalMembers: 2,
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: MessageGroupWidget(
                group: MessageGroup(
                  senderId: plain.senderId,
                  senderName: plain.senderName,
                  isMe: false,
                  messages: const [plain],
                ),
                roomId: '!room:example.org',
                messageIndex: const {r'$plain': plain},
                membersById: const {},
                showAvatar: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.byKey(const ValueKey('text-bubble:\$plain')));
      await tester.pumpAndSettle();

      expect(find.text('全屏阅读'), findsNothing);
    });
  });
}
