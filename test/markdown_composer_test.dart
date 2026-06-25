import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/markdown/markdown_composer.dart';

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

  test('raw HTML is treated as text', () {
    final result = composer.compile('<script>alert("x")</script>');

    expect(result.body, '<script>alert("x")</script>');
    expect(result.formattedBody, isNull);
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

  test('turns full Matrix user IDs into intentional mentions', () {
    final result = composer.compile('hello @alice:example.org');

    expect(result.mentionedUserIds, ['@alice:example.org']);
    expect(
      result.formattedBody,
      contains('https://matrix.to/#/%40alice%3Aexample.org'),
    );
  });
}
