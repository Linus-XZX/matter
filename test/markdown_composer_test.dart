import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/markdown/markdown_composer.dart';
import 'package:matter/features/matrix_html/matrix_html_parser.dart';

void main() {
  const composer = MarkdownComposer();

  test('compiles supported markdown to Matrix HTML and readable fallback', () {
    final result = composer.compile('''
**Hello** [Alice](https://matrix.to/#/@alice:example.org)

- item 1
- item 2
''');

    expect(result.body, 'Hello Alice\n\n- item 1\n- item 2');
    expect(result.formattedBody, contains('<strong>Hello</strong>'));
    expect(
      result.formattedBody,
      contains('<a href="https://matrix.to/#/@alice:example.org">Alice</a>'),
    );
    expect(result.formattedBody, contains('<ul><li>'));
    expect(result.mentionedUserIds, ['@alice:example.org']);
    expect(result.mentionsRoom, isFalse);
  });

  test('plain text does not create formatted_body', () {
    final result = composer.compile('hello world');

    expect(result.body, 'hello world');
    expect(result.formattedBody, isNull);
  });

  test('standalone rich blocks create formatted_body', () {
    expect(composer.compile('- one\n- two').formattedBody, contains('<ul>'));
    expect(
      composer.compile('> quoted').formattedBody,
      contains('<blockquote>'),
    );
    expect(composer.compile('---').formattedBody, contains('<hr'));
  });

  test('plain paragraphs do not create formatted_body', () {
    final result = composer.compile('hello\n\nworld');

    expect(result.body, 'hello\n\nworld');
    expect(result.formattedBody, isNull);
  });

  test('spoilers compile to Matrix HTML without leaking into the fallback', () {
    final result = composer.compile('before ||secret ending|| after');

    expect(result.body, 'before [Spoiler] after');
    expect(
      result.formattedBody,
      '<p>before <span data-mx-spoiler="">secret ending</span> after</p>',
    );
  });

  test('spoiler reasons are preserved in HTML and the fallback', () {
    final result = composer.compile('||plot twist|**Alice** wins||');

    expect(result.body, '[Spoiler for plot twist]');
    expect(
      result.formattedBody,
      '<p><span data-mx-spoiler="plot twist"><strong>Alice</strong> wins</span></p>',
    );
  });

  test('raw HTML passes through to formatted body', () {
    final result = composer.compile('mix <b>bold</b> html');

    expect(result.body, 'mix bold html');
    expect(result.formattedBody, contains('<b>bold</b>'));
  });

  test('HTML blocks pass through verbatim', () {
    final result = composer.compile('<div>block</div>');

    expect(result.body, 'block');
    expect(result.formattedBody, contains('<div>block</div>'));
  });

  test('script tags are discarded by the display parser', () {
    final result = composer.compile('<script>alert("x")</script>after');

    // The composer emits the raw HTML; the display-side whitelist parser is
    // the sanitizer and drops script tags with their contents.
    final nodes = const MatrixHtmlParser().parse(result.formattedBody ?? '');
    expect(nodes.map((node) => node.textContent).join(), 'after');
  });

  test('task lists use Matrix-compatible text markers', () {
    final result = composer.compile('- [ ] todo\n- [x] done');

    expect(result.body, '- [ ] todo\n- [x] done');
    expect(result.formattedBody, isNot(contains('<input')));
    expect(result.formattedBody, contains('<li>[ ] todo</li>'));
    expect(result.formattedBody, contains('<li>[x] done</li>'));
  });

  test('external images degrade to visible alt text', () {
    final result = composer.compile(
      '![a cat](https://example.org/cat.png "my cat")',
    );

    expect(result.body, 'a cat');
    expect(result.formattedBody, '<p>a cat</p>');
    expect(result.formattedBody, isNot(contains('<img')));
  });

  test('mxc images compile to Matrix-compatible img tags', () {
    final result = composer.compile('![a cat](mxc://example.org/cat "my cat")');

    expect(
      result.formattedBody,
      '<p><img alt="a cat" src="mxc://example.org/cat" title="my cat"></p>',
    );
  });

  test('images with unsafe sources degrade to alt text', () {
    final result = composer.compile('![alt](javascript:alert(1))');

    expect(result.formattedBody, isNot(contains('<img')));
    expect(result.formattedBody, isNot(contains('javascript:')));
  });

  test('inline math compiles to data-mx-maths spans', () {
    final result = composer.compile(r'the formula $x^2$ works');

    expect(result.body, r'the formula $x^2$ works');
    expect(result.formattedBody, contains('<span data-mx-maths="x^2"></span>'));
  });

  test('block math compiles to data-mx-maths divs', () {
    final result = composer.compile('\$\$\nx^2 + y^2\n\$\$');

    expect(result.formattedBody, contains('<div data-mx-maths="x^2 + y^2">'));
  });

  test('tables omit attributes stripped by the Matrix sanitizer', () {
    final result = composer.compile(
      '| a | b | c |\n|:---|:---:|---:|\n| 1 | 2 | 3 |',
    );

    expect(result.formattedBody, contains('<th>a</th>'));
    expect(result.formattedBody, contains('<th>b</th>'));
    expect(result.formattedBody, contains('<th>c</th>'));
    expect(result.formattedBody, contains('<td>2</td>'));
    expect(result.formattedBody, isNot(contains(' align=')));
  });

  test('currency amounts are not math', () {
    final result = composer.compile(r'costs $5 and $10 total');

    expect(result.formattedBody, isNot(contains('data-mx-maths')));
  });

  test('unsafe links lose link behavior', () {
    final result = composer.compile('[open](javascript:alert(1))');

    expect(result.body, 'open');
    expect(result.formattedBody, '<p>open</p>');
    expect(result.formattedBody, isNot(contains('javascript:')));
  });

  test('detects room mentions', () {
    final result = composer.compile('hello @room');

    expect(result.mentionsRoom, isTrue);
  });

  test('does not notify the room for code examples', () {
    final result = composer.compile('`@room`');

    expect(result.mentionsRoom, isFalse);
  });

  test('raw HTML code and math do not create mentions', () {
    for (final source in [
      '<pre>@room @alice:example.org</pre>',
      '<code>@room @alice:example.org</code>',
      r'$@room @alice:example.org$',
    ]) {
      final result = composer.compile(source);
      expect(result.mentionsRoom, isFalse, reason: source);
      expect(result.mentionedUserIds, isEmpty, reason: source);
    }
  });

  test('turns full Matrix user IDs into intentional mentions', () {
    final result = composer.compile('hello @alice:example.org');

    expect(result.mentionedUserIds, ['@alice:example.org']);
    expect(
      result.formattedBody,
      contains('https://matrix.to/#/%40alice%3Aexample.org'),
    );
  });

  test('collects mentions from supported Matrix user permalinks', () {
    final matrixUri = composer.compile('[Alice](matrix:u/alice:example.org)');
    final matrixTo = composer.compile(
      '[Alice](https://matrix.to/#/@alice:example.org?via=example.org)',
    );

    expect(matrixUri.mentionedUserIds, ['@alice:example.org']);
    expect(matrixTo.mentionedUserIds, ['@alice:example.org']);
  });
}
