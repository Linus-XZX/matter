import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/send_flight.dart';
import 'package:matter/providers/chat_provider.dart';

void main() {
  test('send flight id stays stable across optimistic states', () {
    expect(sendFlightId('${localOutgoingPendingPrefix}42'), '42');
    expect(sendFlightId('${localOutgoingSentPrefix}42'), '42');
    expect(sendFlightId('${localOutgoingFailedPrefix}42'), '42');
  });

  testWidgets('send flight reveals the target after reaching it', (
    tester,
  ) async {
    const messageId = '${localOutgoingPendingPrefix}flight-test';
    const sourceKey = ValueKey('flight-source');
    const targetKey = ValueKey('flight-target');
    registerSendFlight(
      messageId,
      const SendFlightSpec(
        sourceRect: Rect.fromLTWH(20, 500, 180, 44),
        kind: SendFlightKind.text,
        child: ColoredBox(key: sourceKey, color: Colors.blue),
      ),
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomRight,
            child: SendFlightTarget(
              messageId: messageId,
              child: SizedBox(key: targetKey, width: 90, height: 40),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(sourceKey), findsOneWidget);
    final hiddenTarget = tester.widget<Opacity>(
      find.ancestor(of: find.byKey(targetKey), matching: find.byType(Opacity)),
    );
    expect(hiddenTarget.opacity, 0);

    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(sourceKey), findsNothing);
    final visibleTarget = tester.widget<Opacity>(
      find.ancestor(of: find.byKey(targetKey), matching: find.byType(Opacity)),
    );
    expect(visibleTarget.opacity, 1);

    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('send flight animates from source rect to target rect', (
    tester,
  ) async {
    const messageId = '${localOutgoingPendingPrefix}flight-path-test';
    const sourceKey = ValueKey('flight-source-path');
    const targetKey = ValueKey('flight-target-path');
    const sourceRect = Rect.fromLTWH(20, 500, 180, 44);
    registerSendFlight(
      messageId,
      const SendFlightSpec(
        sourceRect: sourceRect,
        kind: SendFlightKind.text,
        child: ColoredBox(key: sourceKey, color: Colors.blue),
      ),
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomRight,
            child: SendFlightTarget(
              messageId: messageId,
              child: SizedBox(key: targetKey, width: 90, height: 40),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // The overlay should exist and start near the source position.
    expect(find.byKey(sourceKey), findsOneWidget);
    final startPositioned = tester.widget<Positioned>(
      find.ancestor(
        of: find.byKey(sourceKey),
        matching: find.byType(Positioned),
      ),
    );
    expect(startPositioned.left, closeTo(sourceRect.left, 1));
    expect(startPositioned.top, closeTo(sourceRect.top, 1));

    // Halfway through the animation it should be between source and target.
    await tester.pump(const Duration(milliseconds: 180));
    expect(find.byKey(sourceKey), findsOneWidget);
    final midPositioned = tester.widget<Positioned>(
      find.ancestor(
        of: find.byKey(sourceKey),
        matching: find.byType(Positioned),
      ),
    );
    expect(midPositioned.left, greaterThan(sourceRect.left + 50));

    // At the end it should have reached the target area.
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.byKey(sourceKey), findsNothing);

    // Drain the cleanup timer registered by registerSendFlight.
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('text flight lands exactly on its target rect', (tester) async {
    const messageId = '${localOutgoingPendingPrefix}text-status-space';
    const sourceKey = ValueKey('text-status-source');
    const targetRect = Rect.fromLTWH(220, 300, 90, 40);
    registerSendFlight(
      messageId,
      const SendFlightSpec(
        sourceRect: Rect.fromLTWH(20, 500, 180, 44),
        kind: SendFlightKind.text,
        child: ColoredBox(key: sourceKey, color: Colors.blue),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned(
                left: targetRect.left,
                top: targetRect.top,
                child: const SendFlightTarget(
                  messageId: messageId,
                  child: SizedBox(width: 90, height: 40),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 299));

    final positioned = tester.widget<Positioned>(
      find.ancestor(
        of: find.byKey(sourceKey),
        matching: find.byType(Positioned),
      ),
    );
    expect(positioned.left, closeTo(targetRect.left, 1));
    expect(positioned.width, closeTo(targetRect.width, 1));

    final decoratedBox = tester.widget<DecoratedBox>(
      find.ancestor(
        of: find.byKey(sourceKey),
        matching: find.byType(DecoratedBox),
      ),
    );
    final decoration = decoratedBox.decoration as BoxDecoration;
    final radius = decoration.borderRadius! as BorderRadius;
    expect(
      radius.bottomRight.x,
      closeTo(outgoingTextBubbleBorderRadius.bottomRight.x, 0.1),
    );
    expect(
      radius.bottomLeft.x,
      closeTo(outgoingTextBubbleBorderRadius.bottomLeft.x, 0.1),
    );

    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('each flight lands at its own target position', (tester) async {
    const firstMessage = '${localOutgoingPendingPrefix}rapid-1';
    const secondMessage = '${localOutgoingPendingPrefix}rapid-2';
    const firstSourceKey = ValueKey('rapid-source-1');
    const secondSourceKey = ValueKey('rapid-source-2');
    const firstTargetKey = ValueKey('rapid-target-1');
    const secondTargetKey = ValueKey('rapid-target-2');

    registerSendFlight(
      firstMessage,
      const SendFlightSpec(
        sourceRect: Rect.fromLTWH(20, 500, 80, 40),
        kind: SendFlightKind.text,
        child: ColoredBox(key: firstSourceKey, color: Colors.red),
      ),
    );
    registerSendFlight(
      secondMessage,
      const SendFlightSpec(
        sourceRect: Rect.fromLTWH(120, 500, 80, 40),
        kind: SendFlightKind.text,
        child: ColoredBox(key: secondSourceKey, color: Colors.blue),
      ),
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SendFlightTarget(
                messageId: firstMessage,
                child: SizedBox(key: firstTargetKey, width: 80, height: 40),
              ),
              SendFlightTarget(
                messageId: secondMessage,
                child: SizedBox(key: secondTargetKey, width: 80, height: 40),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    // Let both animations run most of the way.
    await tester.pump(const Duration(milliseconds: 280));

    // Each source widget should be near its own target: in this Column the
    // second target is visually below the first, so the second flight ends
    // lower on screen.
    final firstPositioned = tester.widget<Positioned>(
      find.ancestor(
        of: find.byKey(firstSourceKey),
        matching: find.byType(Positioned),
      ),
    );
    final secondPositioned = tester.widget<Positioned>(
      find.ancestor(
        of: find.byKey(secondSourceKey),
        matching: find.byType(Positioned),
      ),
    );
    expect(firstPositioned.top, lessThan(secondPositioned.top ?? 0));

    // Let animations finish and drain cleanup timers.
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('sticker flight ends exactly on the target rect', (tester) async {
    const messageId = '${localOutgoingPendingPrefix}sticker-flight';
    const sourceKey = ValueKey('sticker-source');
    const targetKey = ValueKey('sticker-target');
    const sourceRect = Rect.fromLTWH(100, 600, 80, 80);
    const targetRect = Rect.fromLTWH(200, 300, 100, 100);

    registerSendFlight(
      messageId,
      const SendFlightSpec(
        sourceRect: sourceRect,
        kind: SendFlightKind.sticker,
        child: ColoredBox(key: sourceKey, color: Colors.green),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned(
                left: targetRect.left,
                top: targetRect.top,
                child: const SendFlightTarget(
                  messageId: messageId,
                  child: SizedBox(key: targetKey, width: 100, height: 100),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    // Start should match source.
    final startPositioned = tester.widget<Positioned>(
      find.ancestor(
        of: find.byKey(sourceKey),
        matching: find.byType(Positioned),
      ),
    );
    expect(startPositioned.left, closeTo(sourceRect.left, 1));
    expect(startPositioned.top, closeTo(sourceRect.top, 1));

    // Just before completion the overlay should be at the target rect.
    await tester.pump(const Duration(milliseconds: 359));
    final endPositioned = tester.widget<Positioned>(
      find.ancestor(
        of: find.byKey(sourceKey),
        matching: find.byType(Positioned),
      ),
    );
    expect(endPositioned.left, closeTo(targetRect.left, 1));
    expect(endPositioned.top, closeTo(targetRect.top, 1));
    expect(endPositioned.width, closeTo(targetRect.width, 1));
    expect(endPositioned.height, closeTo(targetRect.height, 1));

    // Run to completion and let the overlay entry remove itself.
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(sourceKey), findsNothing);

    // Drain cleanup timers.
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('send flight follows the target if it moves before completion', (
    tester,
  ) async {
    const messageId = '${localOutgoingPendingPrefix}moving-target';
    const sourceKey = ValueKey('moving-source');
    const targetKey = ValueKey('moving-target');
    const sourceRect = Rect.fromLTWH(100, 560, 80, 80);
    var targetTop = 420.0;
    late StateSetter setTargetState;

    registerSendFlight(
      messageId,
      const SendFlightSpec(
        sourceRect: sourceRect,
        kind: SendFlightKind.sticker,
        child: ColoredBox(key: sourceKey, color: Colors.green),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              setTargetState = setState;
              return Stack(
                children: [
                  Positioned(
                    left: 220,
                    top: targetTop,
                    child: const SendFlightTarget(
                      messageId: messageId,
                      child: SizedBox(key: targetKey, width: 96, height: 64),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.pump(const Duration(milliseconds: 120));
    setTargetState(() => targetTop = 260);
    await tester.pump();

    await tester.pump(const Duration(milliseconds: 239));
    final endPositioned = tester.widget<Positioned>(
      find.ancestor(
        of: find.byKey(sourceKey),
        matching: find.byType(Positioned),
      ),
    );
    expect(endPositioned.left, closeTo(220, 1));
    expect(endPositioned.top, closeTo(260, 1));
    expect(endPositioned.width, closeTo(96, 1));
    expect(endPositioned.height, closeTo(64, 1));

    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets(
    'send flight can land on a remote target using the local flight id',
    (tester) async {
      const pendingMessageId = '${localOutgoingPendingPrefix}remote-handoff';
      const sourceKey = ValueKey('handoff-source');
      const targetKey = ValueKey('handoff-target');
      const sourceRect = Rect.fromLTWH(100, 560, 80, 80);
      const targetRect = Rect.fromLTWH(260, 220, 90, 70);

      registerSendFlight(
        pendingMessageId,
        const SendFlightSpec(
          sourceRect: sourceRect,
          kind: SendFlightKind.sticker,
          child: ColoredBox(key: sourceKey, color: Colors.green),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  left: targetRect.left,
                  top: targetRect.top,
                  child: const SendFlightTarget(
                    messageId: r'$remote-event',
                    flightId: 'remote-handoff',
                    child: SizedBox(key: targetKey, width: 90, height: 70),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.pump(const Duration(milliseconds: 359));
      final endPositioned = tester.widget<Positioned>(
        find.ancestor(
          of: find.byKey(sourceKey),
          matching: find.byType(Positioned),
        ),
      );
      expect(endPositioned.left, closeTo(targetRect.left, 1));
      expect(endPositioned.top, closeTo(targetRect.top, 1));
      expect(endPositioned.width, closeTo(targetRect.width, 1));
      expect(endPositioned.height, closeTo(targetRect.height, 1));

      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(seconds: 2));
    },
  );
}
