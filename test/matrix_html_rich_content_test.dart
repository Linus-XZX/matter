import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matter/features/matrix_html/matrix_html_renderer.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Widget app(String html) => ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        body: MatrixHtmlMessage(
          html: html,
          style: const TextStyle(fontSize: 15, color: Colors.white),
          accentColor: Colors.cyan,
        ),
      ),
    ),
  );

  group('code blocks', () {
    testWidgets('code block fills the available width', (tester) async {
      await tester.pumpWidget(app('<pre><code>short</code></pre>'));

      expect(tester.takeException(), isNull);
      final scroll = tester.getSize(
        find.descendant(
          of: find.byType(MatrixHtmlMessage),
          matching: find.byType(SingleChildScrollView),
        ),
      );
      // The default test surface is 800 logical pixels wide.
      expect(scroll.width, 780);
    });

    testWidgets('long code stays scrollable inside the same width', (
      tester,
    ) async {
      final longLine = 'x' * 5000;
      await tester.pumpWidget(app('<pre><code>$longLine</code></pre>'));

      expect(tester.takeException(), isNull);
      final scroll = tester.getSize(find.byType(SingleChildScrollView));
      expect(scroll.width, 780);
    });

    testWidgets('highlighted code renders without crashing', (tester) async {
      await tester.pumpWidget(
        app(
          '<pre><code class="language-dart">void main() { print(1); }</code></pre>',
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.textContaining('print', findRichText: true), findsWidgets);
    });

    testWidgets('unknown languages fall back to plain code', (tester) async {
      await tester.pumpWidget(
        app('<pre><code class="language-brainfuck">++++</code></pre>'),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('++++', findRichText: true), findsOneWidget);
    });
  });

  group('task lists', () {
    testWidgets('checkboxes replace bullet markers', (tester) async {
      await tester.pumpWidget(
        app(
          '<ul><li><input type="checkbox" checked> done</li>'
          '<li><input type="checkbox"> todo</li></ul>',
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.check_box_rounded), findsOneWidget);
      expect(
        find.byIcon(Icons.check_box_outline_blank_rounded),
        findsOneWidget,
      );
      expect(find.text(' done', findRichText: true), findsOneWidget);
      expect(find.text(' todo', findRichText: true), findsOneWidget);
      expect(find.text('•', findRichText: true), findsNothing);
    });

    testWidgets('checkboxes nested in paragraphs are detected', (tester) async {
      await tester.pumpWidget(
        app('<ul><li><p><input type="checkbox"> task</p></li></ul>'),
      );

      expect(tester.takeException(), isNull);
      expect(
        find.byIcon(Icons.check_box_outline_blank_rounded),
        findsOneWidget,
      );
    });
  });

  group('math', () {
    testWidgets('block math renders', (tester) async {
      await tester.pumpWidget(app('<div data-mx-maths="x^2 + y^2"></div>'));

      expect(tester.takeException(), isNull);
    });

    testWidgets('inline math renders inside text', (tester) async {
      await tester.pumpWidget(
        app('<p>a <span data-mx-maths="x^2"></span> b</p>'),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('broken math falls back to the raw source', (tester) async {
      await tester.pumpWidget(app('<div data-mx-maths="x^"></div>'));

      expect(tester.takeException(), isNull);
      expect(find.text(r'$$x^$$', findRichText: true), findsOneWidget);
    });
  });

  group('alignment', () {
    testWidgets('aligned paragraphs render with the matching textAlign', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          '<p align="center">middle</p>'
          '<p align="right">right</p>'
          '<div align="center">div middle</div>'
          '<center>legacy center</center>',
        ),
      );

      expect(tester.takeException(), isNull);
      final richTexts = tester
          .widgetList<RichText>(find.byType(RichText))
          .toList();
      TextAlign? alignOf(String text) => richTexts
          .where((rich) => rich.text.toPlainText().contains(text))
          .map((rich) => rich.textAlign)
          .firstOrNull;
      expect(alignOf('middle'), TextAlign.center);
      expect(alignOf('right'), TextAlign.right);
      expect(alignOf('div middle'), TextAlign.center);
      expect(alignOf('legacy center'), TextAlign.center);
    });

    testWidgets('table column alignment reaches the cells', (tester) async {
      await tester.pumpWidget(
        app(
          '<table><thead><tr><th align="center">h</th></tr></thead>'
          '<tbody><tr><td align="right">v</td></tr></tbody></table>',
        ),
      );

      expect(tester.takeException(), isNull);
      final richTexts = tester
          .widgetList<RichText>(find.byType(RichText))
          .toList();
      expect(
        richTexts
            .firstWhere((rich) => rich.text.toPlainText().contains('h'))
            .textAlign,
        TextAlign.center,
      );
      expect(
        richTexts
            .firstWhere((rich) => rich.text.toPlainText().contains('v'))
            .textAlign,
        TextAlign.right,
      );
    });
  });

  group('horizontal rules', () {
    testWidgets('hr ignores the app divider theme indent', (tester) async {
      // The app-wide DividerTheme uses indent: 72 for settings-style list
      // separators; a markdown rule must stay full-width under it.
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: ThemeData(
              dividerTheme: const DividerThemeData(
                color: Colors.grey,
                thickness: 0.5,
                indent: 72,
              ),
            ),
            home: const Scaffold(
              body: MatrixHtmlMessage(
                html: '<h2>title</h2><hr>',
                style: TextStyle(fontSize: 15, color: Colors.white),
                accentColor: Colors.cyan,
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      final divider = tester.widget<Divider>(find.byType(Divider));
      expect(divider.indent, 0);
      expect(divider.endIndent, 0);
      expect(divider.thickness, 1);
      expect(
        tester.getTopLeft(find.byType(Divider)).dx,
        tester.getTopLeft(find.text('title', findRichText: true)).dx,
      );
    });
  });

  group('images', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets('image blocks fall back to alt text when unloading', (
      tester,
    ) async {
      // mxc sources need the Rust bridge to resolve; in tests that call
      // fails, so the widget deterministically lands on the alt fallback.
      await tester.pumpWidget(
        app('<p><img src="mxc://example.org/cat" alt="a cat"></p>'),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('a cat', findRichText: true), findsOneWidget);
    });

    testWidgets('figure captions render below the image', (tester) async {
      await tester.pumpWidget(
        app(
          '<figure><img src="mxc://example.org/a">'
          '<figcaption>a nice caption</figcaption></figure>',
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('a nice caption', findRichText: true), findsOneWidget);
    });

    testWidgets('img title renders as caption', (tester) async {
      await tester.pumpWidget(
        app('<p><img src="mxc://example.org/a" title="the title"></p>'),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('the title', findRichText: true), findsOneWidget);
    });
  });
}
