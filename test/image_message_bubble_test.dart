import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/image_message_bubble.dart';

void main() {
  testWidgets('sticker uses a small repaint-isolated bubble without Hero', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: ImageMessageBubble(
              imageUrl: 'https://example.org/sticker.png',
              imageWidth: 512,
              imageHeight: 512,
              timestamp: '12:00',
              isMe: false,
              heroTag: 'sticker-test',
              isSticker: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(Hero), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('msg-image:sticker-test'))),
      const Size(160, 160),
    );
  });
}
