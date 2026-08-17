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

  test('keeps images with safe sources, alt, and title', () {
    final nodes = parser.parse(
      '<p><img src="mxc://example.org/abc" alt="a cat" title="my cat"></p>',
    );

    final paragraph = nodes.single as MatrixElementNode;
    final img = paragraph.children.whereType<MatrixElementNode>().single;
    expect(img.tag, 'img');
    expect(img.attributes['src'], 'mxc://example.org/abc');
    expect(img.attributes['alt'], 'a cat');
    expect(img.attributes['title'], 'my cat');
  });

  test('images with unsafe sources fall back to alt text', () {
    final nodes = parser.parse(
      '<p><img src="javascript:alert(1)" alt="alt text"></p>',
    );

    final paragraph = nodes.single as MatrixElementNode;
    expect(paragraph.children.whereType<MatrixElementNode>(), isEmpty);
    expect(paragraph.textContent, 'alt text');
  });

  test('keeps figure and figcaption structure', () {
    final nodes = parser.parse(
      '<figure><img src="https://example.org/a.png">'
      '<figcaption>a <em>caption</em></figcaption></figure>',
    );

    final figure = nodes.single as MatrixElementNode;
    expect(figure.tag, 'figure');
    final tags = figure.children.whereType<MatrixElementNode>().map(
      (node) => node.tag,
    );
    expect(tags, ['img', 'figcaption']);
  });

  test('keeps task-list checkboxes and drops other inputs', () {
    final nodes = parser.parse(
      '<ul><li><input type="checkbox" checked> done</li>'
      '<li><input type="text"> field</li></ul>',
    );

    final list = nodes.single as MatrixElementNode;
    final items = list.children.whereType<MatrixElementNode>().toList();
    final checkbox = items[0].children.whereType<MatrixElementNode>().single;
    expect(checkbox.tag, 'input');
    expect(checkbox.attributes['checked'], 'true');
    expect(items[0].textContent, ' done');
    expect(items[1].children.whereType<MatrixElementNode>(), isEmpty);
    expect(items[1].textContent, ' field');
  });

  test('keeps data-mx-maths on spans and divs only', () {
    final nodes = parser.parse(
      '<span data-mx-maths="x^2" onclick="evil()"></span>'
      '<div data-mx-maths="y^2"></div>',
    );

    final span = nodes[0] as MatrixElementNode;
    expect(span.tag, 'span');
    expect(span.attributes, {'data-mx-maths': 'x^2'});
    final div = nodes[1] as MatrixElementNode;
    expect(div.tag, 'div');
    expect(div.attributes, {'data-mx-maths': 'y^2'});

    final plain = parser.parse('<div>plain</div>');
    expect(plain.single, isA<MatrixTextNode>());
  });

  test('keeps whitelisted align attributes', () {
    final nodes = parser.parse(
      '<p align="center">c</p><h1 align="right">h</h1>'
      '<div align="justify">j</div><table><tr><th align="center">t</th></tr></table>',
    );

    expect((nodes[0] as MatrixElementNode).attributes['align'], 'center');
    expect((nodes[1] as MatrixElementNode).attributes['align'], 'right');
    final div = nodes[2] as MatrixElementNode;
    expect(div.tag, 'div');
    expect(div.attributes['align'], 'justify');
    final table = nodes[3] as MatrixElementNode;
    MatrixElementNode? cell;
    void findCell(MatrixElementNode node) {
      for (final child in node.children) {
        if (child is MatrixElementNode) {
          if (child.tag == 'th') cell ??= child;
          findCell(child);
        }
      }
    }

    findCell(table);
    expect(cell?.attributes['align'], 'center');
  });

  test('maps center tags to centered divs and drops invalid align', () {
    final centered = parser.parse('<center>middle</center>');
    final div = centered.single as MatrixElementNode;
    expect(div.tag, 'div');
    expect(div.attributes, {'align': 'center'});
    expect(div.textContent, 'middle');

    final invalid = parser.parse('<p align="top">x</p>');
    expect(
      (invalid.single as MatrixElementNode).attributes,
      isNot(contains('align')),
    );
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
