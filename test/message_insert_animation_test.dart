import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/message_insert_animation.dart';

void main() {
  testWidgets('expands a new message upward to its full height', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: MessageInsertAnimation(
              child: SizedBox(width: 120, height: 48),
            ),
          ),
        ),
      ),
    );

    final sizeTransition = find.byType(SizeTransition);
    expect(tester.getSize(sizeTransition).height, 0);

    await tester.pump(const Duration(milliseconds: 120));
    final middleHeight = tester.getSize(sizeTransition).height;
    expect(middleHeight, greaterThan(0));
    expect(middleHeight, lessThan(48));

    await tester.pumpAndSettle();
    expect(tester.getSize(sizeTransition).height, 48);
  });

  testWidgets('keeps an outgoing message anchored to the right', (
    tester,
  ) async {
    const childKey = ValueKey('outgoing-message');
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: 320,
              child: MessageInsertAnimation(
                child: SizedBox(key: childKey, width: 120, height: 48),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 120));
    final containerRect = tester.getRect(find.byType(MessageInsertAnimation));
    final childRect = tester.getRect(find.byKey(childKey));
    expect(childRect.right, containerRect.right);
  });
}
