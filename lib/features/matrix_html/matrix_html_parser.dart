import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import '../markdown/markdown_composer.dart';
import 'matrix_html_node.dart';

class MatrixHtmlParser {
  static const maxDepth = 100;
  static const _allowedTags = {
    'p',
    'strong',
    'b',
    'em',
    'i',
    'del',
    's',
    'code',
    'pre',
    'blockquote',
    'ul',
    'ol',
    'li',
    'a',
    'br',
    'hr',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'span',
  };
  static const _discardWithContents = {'script', 'style', 'iframe', 'object'};

  const MatrixHtmlParser();

  List<MatrixHtmlNode> parse(String source) {
    final fragment = html.parseFragment(source);
    return _parseChildren(fragment.nodes, 0);
  }

  List<MatrixHtmlNode> _parseChildren(List<dom.Node> nodes, int depth) {
    if (depth > maxDepth) return const [];
    final result = <MatrixHtmlNode>[];
    for (final node in nodes) {
      if (node is dom.Text) {
        if (node.data.isNotEmpty) result.add(MatrixTextNode(node.data));
        continue;
      }
      if (node is! dom.Element) continue;
      final tag = node.localName?.toLowerCase() ?? '';
      if (_discardWithContents.contains(tag)) continue;
      final children = _parseChildren(node.nodes, depth + 1);
      if (!_allowedTags.contains(tag)) {
        if (tag == 'img') {
          final alt = node.attributes['alt'];
          if (alt != null && alt.isNotEmpty) result.add(MatrixTextNode(alt));
        } else {
          result.addAll(children);
        }
        continue;
      }
      final attributes = <String, String>{};
      if (tag == 'a') {
        final href = safeMatrixHtmlHref(node.attributes['href']);
        if (href != null) attributes['href'] = href;
      } else if (tag == 'ol') {
        final start = int.tryParse(node.attributes['start'] ?? '');
        if (start != null) attributes['start'] = '$start';
      } else if (tag == 'code') {
        final className = node.attributes['class'];
        final language = className == null
            ? null
            : RegExp(
                r'(?:^|\s)language-([A-Za-z0-9_+-]{1,32})(?:\s|$)',
              ).firstMatch(className)?.group(1);
        if (language != null) attributes['class'] = 'language-$language';
      }
      result.add(
        MatrixElementNode(tag: tag, children: children, attributes: attributes),
      );
    }
    return result;
  }
}
