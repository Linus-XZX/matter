import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/matrix_html/matrix_html_node.dart';
import 'package:matter/features/matrix_html/matrix_html_parser.dart';
import 'package:matter/pages/chat/message_text.dart';

void main() {
  const parser = MatrixHtmlParser();

  test('keeps allowed structure and safe attributes', () {
    final nodes = parser.parse(
      '<p>Hello <strong>Alice</strong> '
      '<a href="https://example.org">link</a></p>',
    );

    final paragraph = nodes.single as MatrixElementNode;
    expect(paragraph.tag, 'p');
    expect(paragraph.textContent, 'Hello Alice link');
    final link = paragraph.children.whereType<MatrixElementNode>().last;
    expect(link.attributes['href'], 'https://example.org');
  });

  test('drops unsafe link protocols and dangerous element contents', () {
    final nodes = parser.parse(
      '<p><a href="javascript:alert(1)">open</a>'
      '<script>bad()</script></p>',
    );

    final paragraph = nodes.single as MatrixElementNode;
    final link = paragraph.children.whereType<MatrixElementNode>().single;
    expect(link.attributes, isEmpty);
    expect(paragraph.textContent, 'open');
  });

  test('flattens unknown presentation tags', () {
    final nodes = parser.parse('<p><custom>hello</custom></p>');
    expect(nodes.single.textContent, 'hello');
  });

  group('matrixHtmlTextExcludingCode', () {
    test('drops URLs inside pre and code blocks', () {
      final text = matrixHtmlTextExcludingCode(
        '<pre><code>curl https://example.org/api</code></pre>',
      );
      expect(detectMessageUrls(text), isEmpty);
    });

    test('drops URLs inside inline code', () {
      final text = matrixHtmlTextExcludingCode(
        '<p>run <code>https://example.org</code> locally</p>',
      );
      expect(detectMessageUrls(text), isEmpty);
    });

    test('keeps URLs outside code sections', () {
      final text = matrixHtmlTextExcludingCode(
        '<p>see https://example.org '
        '<code>https://ignored.example</code></p>',
      );
      final urls = detectMessageUrls(text);
      expect(urls.map((match) => match.uri.host), ['example.org']);
    });

    test('keeps text without code sections intact', () {
      final text = matrixHtmlTextExcludingCode(
        '<p>see <strong>https://example.org</strong></p>',
      );
      expect(detectMessageUrls(text), isNotEmpty);
    });

    test('keeps URLs spanning inline tags intact', () {
      final text = matrixHtmlTextExcludingCode(
        '<p>https://example.<strong>org</strong>/path</p>',
      );
      final urls = detectMessageUrls(text);
      expect(urls.map((match) => match.uri.toString()), [
        'https://example.org/path',
      ]);
    });

    test('separates text across block boundaries', () {
      final text = matrixHtmlTextExcludingCode(
        '<p>https://a.example.org</p><p>https://b.example.org</p>',
      );
      final urls = detectMessageUrls(text);
      expect(urls.map((match) => match.uri.host), [
        'a.example.org',
        'b.example.org',
      ]);
    });
  });
}
