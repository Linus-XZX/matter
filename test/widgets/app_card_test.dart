import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/theme/app_theme.dart';
import 'package:matter/widgets/app_card.dart';

void main() {
  group('AppCard', () {
    testWidgets('renders its child', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppCard(child: Text('Hello')),
          ),
        ),
      );

      expect(find.text('Hello'), findsOneWidget);
    });

    testWidgets('uses the default surface color', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppCard(child: SizedBox(width: 100, height: 100)),
          ),
        ),
      );

      final container = tester.widget<Container>(
        find.ancestor(
          of: find.byType(SizedBox),
          matching: find.byType(Container),
        ),
      );
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.color, AppColors.surface);
    });

    testWidgets('uses a custom color when provided', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppCard(
              color: Colors.red,
              child: SizedBox(width: 100, height: 100),
            ),
          ),
        ),
      );

      final container = tester.widget<Container>(
        find.ancestor(
          of: find.byType(SizedBox),
          matching: find.byType(Container),
        ),
      );
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.color, Colors.red);
    });

    testWidgets('calls onTap when tapped', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppCard(
              onTap: () => tapped = true,
              child: const Text('Tap me'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Tap me'));
      expect(tapped, isTrue);
    });
  });
}
