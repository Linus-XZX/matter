import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/widgets/liquid_glass.dart';

void main() {
  group('LiquidGlassContainer', () {
    testWidgets('renders its child inside a clipped backdrop blur', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LiquidGlassContainer(child: Text('Glass')),
          ),
        ),
      );

      expect(find.text('Glass'), findsOneWidget);
      expect(find.byType(ClipRRect), findsOneWidget);
      expect(find.byType(BackdropFilter), findsOneWidget);
    });

    testWidgets('applies custom margin and padding', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LiquidGlassContainer(
              margin: EdgeInsets.all(8),
              padding: EdgeInsets.all(4),
              child: SizedBox(width: 100, height: 100),
            ),
          ),
        ),
      );

      final outerPadding = tester.widget<Padding>(find.byType(Padding).first);
      expect(outerPadding.padding, const EdgeInsets.all(8));

      final innerContainer = tester.widget<Container>(
        find.descendant(
          of: find.byType(BackdropFilter),
          matching: find.byType(Container),
        ),
      );
      expect(innerContainer.padding, const EdgeInsets.all(4));
    });
  });
}
