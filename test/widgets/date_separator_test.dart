import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/date_separator.dart';

void main() {
  group('DateSeparator', () {
    testWidgets('renders the date label between two dividers', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DateSeparator(dateLabel: '今天'),
          ),
        ),
      );

      expect(find.text('今天'), findsOneWidget);
      expect(find.byType(Container), findsNWidgets(2));
    });

    testWidgets('applies symmetric padding', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DateSeparator(dateLabel: '昨天'),
          ),
        ),
      );

      final padding = tester.widget<Padding>(
        find.ancestor(
          of: find.byType(Row),
          matching: find.byType(Padding),
        ),
      );
      expect(padding.padding, const EdgeInsets.symmetric(vertical: 12, horizontal: 16));
    });
  });
}
