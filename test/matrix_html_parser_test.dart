import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/matrix_html/matrix_html_node.dart';
import 'package:matter/features/matrix_html/matrix_html_parser.dart';

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
}
