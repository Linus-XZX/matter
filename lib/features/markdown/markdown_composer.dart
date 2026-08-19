import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:markdown/markdown.dart' as md;

import '../../src/rust/api/matrix.dart' as rust;
import '../matrix_html/matrix_link_router.dart';

class CompiledMarkdownMessage {
  final String source;
  final String body;
  final String? formattedBody;
  final List<String> mentionedUserIds;
  final bool mentionsRoom;

  const CompiledMarkdownMessage({
    required this.source,
    required this.body,
    required this.formattedBody,
    required this.mentionedUserIds,
    required this.mentionsRoom,
  });

  rust.FormattedMessageInput toRust() => rust.FormattedMessageInput(
    body: body,
    formattedBody: formattedBody,
    mentionedUserIds: mentionedUserIds,
    mentionsRoom: mentionsRoom,
  );
}

class MarkdownComposer {
  const MarkdownComposer();

  CompiledMarkdownMessage compile(String markdown) {
    final source = markdown.trim();
    final nodes = _newDocument().parse(source);
    final mentions = <String>{};
    final htmlRenderer = _MatrixMarkdownHtmlRenderer(mentions);
    final html = htmlRenderer.render(nodes).trim();
    final body = _PlainMarkdownRenderer().render(nodes).trim();
    final hasRichBlock = nodes.any(
      (node) => node is md.Element && node.tag != 'p',
    );
    // Inline-only rich content (math spans keep their `$…$` markers in the
    // plain body, so `source == body` alone would suppress formatted_body).
    final hasRichInline = _hasRichInline(nodes);
    final formattedBody =
        (source == body &&
                mentions.isEmpty &&
                !hasRichBlock &&
                !hasRichInline) ||
            html.isEmpty
        ? null
        : html;

    return CompiledMarkdownMessage(
      source: source,
      body: body,
      formattedBody: formattedBody,
      mentionedUserIds: mentions.toList()..sort(),
      mentionsRoom: htmlRenderer.mentionsRoom,
    );
  }

  md.Document _newDocument() => md.Document(
    blockSyntaxes: [
      const md.FencedCodeBlockSyntax(),
      const _MathBlockSyntax(),
      const md.EmptyBlockSyntax(),
      const md.SetextHeaderSyntax(),
      const md.HeaderSyntax(),
      const md.CodeBlockSyntax(),
      const md.BlockquoteSyntax(),
      const md.HorizontalRuleSyntax(),
      const md.TableSyntax(),
      const md.UnorderedListWithCheckboxSyntax(),
      const md.OrderedListWithCheckboxSyntax(),
      const md.LinkReferenceDefinitionSyntax(),
      const _RawHtmlBlockSyntax(),
      const md.ParagraphSyntax(),
    ],
    inlineSyntaxes: [
      _SpoilerInlineSyntax(),
      md.StrikethroughSyntax(),
      md.AutolinkExtensionSyntax(),
      _RawHtmlInlineSyntax(),
      _MathInlineSyntax(),
    ],
    extensionSet: md.ExtensionSet.none,
    withDefaultBlockSyntaxes: false,
    encodeHtml: false,
  );
}

/// AST tags carrying raw HTML that is emitted verbatim into
/// `formatted_body`. (A `md.Text` subclass would not survive parsing: the
/// inline parser merges adjacent text nodes, dropping any marker subclass.)
/// The display-side `MatrixHtmlParser` whitelist is the sanitizer, so
/// escaping here would show the tags literally instead.
const rawHtmlInlineTag = 'raw-html';
const rawHtmlBlockTag = 'raw-html-block';

/// Like [md.HtmlBlockSyntax], but wraps the result in a marked element so
/// the composer renderers can tell raw HTML apart from ordinary text.
class _RawHtmlBlockSyntax extends md.HtmlBlockSyntax {
  const _RawHtmlBlockSyntax();

  @override
  md.Node parse(md.BlockParser parser) {
    final childLines = parseChildLines(parser);
    var text = childLines.map((e) => e.content).join('\n').trimRight();
    if (parser.previousSyntax != null || parser.parentSyntax != null) {
      text = '\n$text';
      if (parser.parentSyntax is md.ListSyntax) {
        text = '$text\n';
      }
    }
    return md.Element.text(rawHtmlBlockTag, text);
  }
}

/// Like [md.InlineHtmlSyntax], but wraps the matched tag in a marked element
/// instead of letting it merge into surrounding plain text.
class _RawHtmlInlineSyntax extends md.InlineHtmlSyntax {
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text(rawHtmlInlineTag, match[0]!));
    return true;
  }
}

/// Inline math: `$...$`. Follows the pandoc-style heuristics (opening `$`
/// not followed by a space, closing `$` not preceded by a space and not
/// followed by a digit) so currency text like "$5 and $10" is left alone.
class _MathInlineSyntax extends md.InlineSyntax {
  _MathInlineSyntax()
    : super(
        r'(?<!\\)\$(?!\$|\s)((?:\\.|[^$\\\n])+?)(?<![\s\\])\$(?!\d)',
        startCharacter: 0x24, // $
      );

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final tex = match[1] ?? '';
    if (tex.isEmpty) return false;
    parser.addNode(
      md.Element.text('span', tex)..attributes['data-mx-maths'] = '',
    );
    return true;
  }
}

/// FluffyChat-compatible spoilers: `||hidden||` or
/// `||reason|hidden||`.
class _SpoilerInlineSyntax extends md.InlineSyntax {
  _SpoilerInlineSyntax()
    : super(
        r'(?<!\\)\|\|((?:\\.|[^|\\\n]|\|(?!\|))+)\|\|',
        startCharacter: 0x7c, // |
      );

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final source = match[1] ?? '';
    final separator = _firstUnescapedPipe(source);
    final reason = separator < 0
        ? null
        : _unescapeSpoilerText(source.substring(0, separator)).trim();
    final content = _unescapeSpoilerText(
      separator < 0 ? source : source.substring(separator + 1),
    );
    if (content.trim().isEmpty) return false;
    parser.addNode(
      md.Element('span', parser.document.parseInline(content))
        ..attributes['data-mx-spoiler'] = reason ?? '',
    );
    return true;
  }

  static int _firstUnescapedPipe(String source) {
    for (var i = 0; i < source.length; i++) {
      if (source.codeUnitAt(i) != 0x7c) continue;
      var slashes = 0;
      for (var j = i - 1; j >= 0 && source.codeUnitAt(j) == 0x5c; j--) {
        slashes++;
      }
      if (slashes.isEven) return i;
    }
    return -1;
  }

  static String _unescapeSpoilerText(String source) =>
      source.replaceAllMapped(RegExp(r'\\([\\|])'), (match) => match[1]!);
}

/// Block math: lines wrapped in `$$` fences, either a single line
/// (`$$x^2$$`) or a multi-line block.
class _MathBlockSyntax extends md.BlockSyntax {
  const _MathBlockSyntax();

  @override
  RegExp get pattern => RegExp(r'^[ \t]*\$\$');

  @override
  md.Node? parse(md.BlockParser parser) {
    final first = parser.current.content.trim();
    parser.advance();
    var body = first.substring(2);
    if (body.length > 2 && body.endsWith(r'$$')) {
      body = body.substring(0, body.length - 2);
    } else {
      final lines = <String>[body];
      while (!parser.isDone) {
        final line = parser.current.content.trimRight();
        parser.advance();
        if (line.endsWith(r'$$')) {
          lines.add(line.substring(0, line.length - 2));
          break;
        }
        lines.add(line);
      }
      body = lines.join('\n');
    }
    body = body.trim();
    if (body.isEmpty) return null;
    return md.Element.text('div', body)..attributes['data-mx-maths'] = '';
  }
}

/// Whether the AST carries inline-level rich content that the plain-text
/// body cannot represent faithfully: raw HTML, images, checkboxes, math.
bool _hasRichInline(List<md.Node> nodes) {
  for (final node in nodes) {
    if (node is! md.Element) continue;
    final tag = node.tag;
    if (tag == rawHtmlInlineTag ||
        tag == rawHtmlBlockTag ||
        tag == 'img' ||
        tag == 'input' ||
        node.attributes.containsKey('data-mx-maths') ||
        node.attributes.containsKey('data-mx-spoiler')) {
      return true;
    }
    if (_hasRichInline(node.children ?? const [])) return true;
  }
  return false;
}

class _MatrixMarkdownHtmlRenderer {
  static const _escape = HtmlEscape(HtmlEscapeMode.element);
  final Set<String> mentions;
  bool mentionsRoom = false;

  _MatrixMarkdownHtmlRenderer(this.mentions);

  String render(List<md.Node> nodes) {
    final rendered = nodes
        .map((node) => _renderNode(node))
        .where((part) => part.isNotEmpty)
        .join();
    return _linkAndCollectMentions(rendered);
  }

  String _linkAndCollectMentions(String source) {
    final fragment = html_parser.parseFragment(source);

    void visit(
      dom.Node node, {
      bool inCode = false,
      bool inLink = false,
      bool inMath = false,
    }) {
      if (node is dom.Text) {
        if (inCode || inMath) return;
        if (RegExp(
          r'(^|\s)@room(?=\s|$|[.,!?;:，。！？；：])',
          multiLine: true,
        ).hasMatch(node.data)) {
          mentionsRoom = true;
        }
        if (inLink) return;
        final replacement = _renderTextWithMentions(node.data);
        if (replacement != _escape.convert(node.data)) {
          node.replaceWith(html_parser.parseFragment(replacement));
        }
        return;
      }
      if (node is! dom.Element) return;

      final tag = node.localName;
      final nextInCode = inCode || tag == 'code' || tag == 'pre';
      final nextInMath = inMath || node.attributes.containsKey('data-mx-maths');
      if (tag == 'script' || tag == 'style') return;

      final nextInLink = inLink || tag == 'a';
      if (!nextInCode && !nextInMath && tag == 'a') {
        final href = node.attributes['href'];
        final uri = href == null ? null : Uri.tryParse(href);
        final userId = uri == null ? null : matrixUserIdFromUri(uri);
        if (userId != null) mentions.add(userId);
      }
      for (final child in node.nodes.toList()) {
        visit(
          child,
          inCode: nextInCode,
          inLink: nextInLink,
          inMath: nextInMath,
        );
      }
    }

    for (final node in fragment.nodes.toList()) {
      visit(node);
    }
    return fragment.outerHtml;
  }

  String _renderNode(md.Node node) {
    if (node is md.Text) {
      return _escape.convert(node.text);
    }
    if (node is! md.Element) return '';

    final children = node.children?.map(_renderNode).join() ?? '';
    switch (node.tag) {
      case rawHtmlInlineTag:
      case rawHtmlBlockTag:
        // Raw HTML passes through unescaped; `children` above is escaped
        // text and must not be used here.
        return node.textContent;
      case 'p':
        return '<p>$children</p>';
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        return '<${node.tag}>$children</${node.tag}>';
      case 'strong':
      case 'em':
      case 'del':
      case 'blockquote':
      case 'ul':
      case 'li':
      case 'table':
      case 'thead':
      case 'tbody':
      case 'tr':
        return '<${node.tag}>$children</${node.tag}>';
      case 'th':
      case 'td':
        return '<${node.tag}>$children</${node.tag}>';
      case 'ol':
        final start = int.tryParse(node.attributes['start'] ?? '');
        final attr = start != null && start != 1 ? ' start="$start"' : '';
        return '<ol$attr>$children</ol>';
      case 'code':
        final language = _safeLanguageClass(node.attributes['class']);
        final attr = language == null ? '' : ' class="language-$language"';
        return '<code$attr>$children</code>';
      case 'pre':
        return '<pre>$children</pre>';
      case 'a':
        final href = _safeHref(node.attributes['href']);
        if (href == null) return children;
        return '<a href="${_escapeAttribute(href)}">$children</a>';
      case 'br':
        return '<br>';
      case 'hr':
        return '<hr>';
      case 'span':
        final spoilerReason = node.attributes['data-mx-spoiler'];
        if (spoilerReason != null) {
          return '<span data-mx-spoiler="${_escapeAttribute(spoilerReason)}">'
              '$children</span>';
        }
        if (node.attributes.containsKey('data-mx-maths')) {
          return '<span data-mx-maths="${_escapeAttribute(node.textContent)}">'
              '</span>';
        }
        return children;
      case 'div':
        if (node.attributes.containsKey('data-mx-maths')) {
          return '<div data-mx-maths="${_escapeAttribute(node.textContent)}">'
              '</div>';
        }
        return children;
      case 'input':
        if (node.attributes['type'] != 'checkbox') return '';
        return node.attributes.containsKey('checked') ? '[x] ' : '[ ] ';
      case 'img':
        final src = safeMatrixHtmlImgSrc(node.attributes['src']);
        if (src == null || Uri.parse(src).scheme != 'mxc') {
          return _escape.convert(node.attributes['alt'] ?? '');
        }
        // Match ruma-html's deterministic attribute ordering so the echoed
        // formatted body still matches the locally stored Markdown source.
        final buffer = StringBuffer('<img');
        final alt = node.attributes['alt'];
        if (alt != null && alt.isNotEmpty) {
          buffer.write(' alt="${_escapeAttribute(alt)}"');
        }
        buffer.write(' src="${_escapeAttribute(src)}"');
        final title = node.attributes['title'];
        if (title != null && title.isNotEmpty) {
          buffer.write(' title="${_escapeAttribute(title)}"');
        }
        buffer.write('>');
        return buffer.toString();
      default:
        return children;
    }
  }

  String _renderTextWithMentions(String text) {
    final pattern = RegExp(r'(?<![\w@])@[A-Za-z0-9._=\-/]+:[A-Za-z0-9.-]+');
    final buffer = StringBuffer();
    var offset = 0;
    for (final match in pattern.allMatches(text)) {
      buffer.write(_escape.convert(text.substring(offset, match.start)));
      final userId = match.group(0)!;
      mentions.add(userId);
      final href = 'https://matrix.to/#/${Uri.encodeComponent(userId)}';
      buffer
        ..write('<a href="')
        ..write(_escapeAttribute(href))
        ..write('">')
        ..write(_escape.convert(userId))
        ..write('</a>');
      offset = match.end;
    }
    buffer.write(_escape.convert(text.substring(offset)));
    return buffer.toString();
  }

  static String? _safeLanguageClass(String? value) {
    if (value == null) return null;
    final match = RegExp(
      r'(?:^|\s)language-([A-Za-z0-9_+-]{1,32})(?:\s|$)',
    ).firstMatch(value);
    return match?.group(1);
  }
}

class _PlainMarkdownRenderer {
  String render(List<md.Node> nodes) {
    final blocks = nodes
        .map((node) => _renderBlock(node, 0))
        .where((text) => text.trim().isNotEmpty);
    return blocks.join('\n\n');
  }

  String _renderBlock(md.Node node, int depth) {
    if (node is md.Text) return node.text;
    if (node is! md.Element) return '';
    if (node.tag == rawHtmlBlockTag) return htmlTextContent(node.textContent);
    if (node.tag == 'div' && node.attributes.containsKey('data-mx-maths')) {
      return '\$\$${node.textContent}\$\$';
    }
    switch (node.tag) {
      case 'p':
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        return _inline(node.children);
      case 'blockquote':
        final text = (node.children ?? const [])
            .map((child) => _renderBlock(child, depth + 1))
            .join('\n\n');
        return text.split('\n').map((line) => '> $line').join('\n');
      case 'ul':
        return _renderList(node, depth, ordered: false);
      case 'ol':
        return _renderList(node, depth, ordered: true);
      case 'table':
        return _renderTable(node);
      case 'pre':
        return node.textContent;
      case 'hr':
        return '---';
      default:
        return _inline(node.children);
    }
  }

  String _renderTable(md.Element table) {
    final rows = <String>[];
    void collectRows(md.Node node) {
      if (node is! md.Element) return;
      if (node.tag == 'tr') {
        rows.add(
          (node.children ?? const [])
              .whereType<md.Element>()
              .map((cell) => _inline(cell.children).trim())
              .join(' | '),
        );
        return;
      }
      for (final child in node.children ?? const <md.Node>[]) {
        collectRows(child);
      }
    }

    collectRows(table);
    return rows.where((row) => row.isNotEmpty).join('\n');
  }

  String _renderList(md.Element list, int depth, {required bool ordered}) {
    final items = (list.children ?? const []).whereType<md.Element>().toList();
    final start = int.tryParse(list.attributes['start'] ?? '') ?? 1;
    return [
      for (var i = 0; i < items.length; i++)
        _renderListItem(items[i], depth, ordered ? '${start + i}. ' : '- '),
    ].join('\n');
  }

  String _renderListItem(md.Element item, int depth, String marker) {
    final children = List<md.Node>.of(item.children ?? const <md.Node>[]);
    // Task lists carry a leading checkbox `input`, either as a direct child
    // (tight lists) or inside the first paragraph (loose lists).
    final taskState = _takeTaskCheckbox(children);
    if (taskState != null) {
      marker = '$marker[${taskState ? 'x' : ' '}] ';
    }
    final parts = <String>[];
    for (final child in children) {
      if (child is md.Element && (child.tag == 'ul' || child.tag == 'ol')) {
        final nested = _renderList(
          child,
          depth + 1,
          ordered: child.tag == 'ol',
        );
        parts.add(
          nested
              .split('\n')
              .map((line) => '${'  ' * (depth + 1)}$line')
              .join('\n'),
        );
      } else {
        parts.add(_renderBlock(child, depth));
      }
    }
    final content = parts.join('\n').trim();
    final lines = content.split('\n');
    return [
      '$marker${lines.first}',
      for (final line in lines.skip(1)) '${' ' * marker.length}$line',
    ].join('\n');
  }

  String _inline(List<md.Node>? nodes) => _visibleMarkdownText(nodes);
}

/// Removes a leading task-list checkbox (`input[type=checkbox]`) from
/// [nodes], looking one level into a leading paragraph, and returns its
/// checked state — or null when the item is not a task.
bool? _takeTaskCheckbox(List<md.Node> nodes) {
  if (nodes.isEmpty) return null;
  final first = nodes.first;
  if (first is md.Element && first.tag == 'input') {
    if (first.attributes['type'] != 'checkbox') return null;
    nodes.removeAt(0);
    return first.attributes.containsKey('checked');
  }
  if (first is md.Element && first.tag == 'p') {
    final paragraphChildren = first.children;
    if (paragraphChildren != null && paragraphChildren.isNotEmpty) {
      final nested = paragraphChildren.first;
      if (nested is md.Element &&
          nested.tag == 'input' &&
          nested.attributes['type'] == 'checkbox') {
        paragraphChildren.removeAt(0);
        return nested.attributes.containsKey('checked');
      }
    }
  }
  return null;
}

/// The plain-text content of an HTML fragment, with all tags stripped.
String htmlTextContent(String htmlSource) {
  final buffer = StringBuffer();
  void walk(dom.Node node) {
    if (node is dom.Text) {
      buffer.write(node.data);
      return;
    }
    for (final child in node.nodes) {
      walk(child);
    }
  }

  walk(html_parser.parseFragment(htmlSource));
  return buffer.toString();
}

/// The visible text of markdown AST nodes: text nodes as-is, images as
/// their alt text, `br` as a line break; everything else recurses. Shared
/// by the plain-text fallback renderer and degraded-table matching so
/// both see the same cell contents.
String _visibleMarkdownText(List<md.Node>? nodes) {
  if (nodes == null) return '';
  final buffer = StringBuffer();
  for (final node in nodes) {
    if (node is md.Text) {
      buffer.write(node.text);
    } else if (node is md.Element) {
      final isMath =
          (node.tag == 'span' || node.tag == 'div') &&
          node.attributes.containsKey('data-mx-maths');
      if (node.tag == rawHtmlInlineTag || node.tag == rawHtmlBlockTag) {
        buffer.write(htmlTextContent(node.textContent));
      } else if (isMath) {
        final fence = node.tag == 'div' ? '\$\$' : '\$';
        buffer.write('$fence${node.textContent}$fence');
      } else if (node.tag == 'span' &&
          node.attributes.containsKey('data-mx-spoiler')) {
        final reason = node.attributes['data-mx-spoiler']!.trim();
        buffer.write(reason.isEmpty ? '[Spoiler]' : '[Spoiler for $reason]');
      } else if (node.tag == 'img') {
        buffer.write(node.attributes['alt'] ?? '');
      } else if (node.tag == 'br') {
        buffer.write('\n');
      } else {
        buffer.write(_visibleMarkdownText(node.children));
      }
    }
  }
  return buffer.toString();
}

/// Rebuilds Matrix HTML from the markdown `body` when the sender's
/// `formatted_body` lost its table structure. Some clients strip `<table>`
/// tags from the HTML they send, leaving the cells as unreadable plain
/// text; the markdown source in `body` still carries the real table.
///
/// Recovery only applies when a `formatted_body` exists and matches the
/// known degraded shape (the table's header cells are still present as
/// flattened text). Plain-text events are never reinterpreted as rich
/// text, and legitimate HTML that intentionally has no table is kept.
///
/// Returns null when recovery does not apply, so callers keep the
/// original rendering path.
String? recoverDegradedTableHtml({
  required String body,
  required String? formattedBody,
  MarkdownComposer composer = const MarkdownComposer(),
}) {
  if (formattedBody == null || formattedBody.contains('<table')) return null;
  if (!markdownBodyHasTable(body)) return null;
  if (!_looksLikeFlattenedTable(
    body: body,
    formattedBody: formattedBody,
    composer: composer,
  )) {
    return null;
  }
  final recovered = composer.compile(body).formattedBody;
  if (recovered == null || !recovered.contains('<table')) return null;
  return recovered;
}

/// Whether [body] contains a markdown table (a header row with `|` followed
/// by a `|---|---|` separator line).
bool markdownBodyHasTable(String body) {
  final separator = RegExp(r'^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$');
  final lines = body.split('\n');
  for (var i = 0; i + 1 < lines.length; i++) {
    if (lines[i].contains('|') && separator.hasMatch(lines[i + 1])) {
      return true;
    }
  }
  return false;
}

/// The known degraded shape: the sender stripped the `<table>` tags but
/// kept every cell as flattened text, in order. Compare the full ordered
/// cell token sequence of the markdown table against the HTML's visible
/// text tokens (extracted with a real HTML parser), so legitimate
/// non-table HTML that merely mentions the same words — or contains the
/// sequence only across word boundaries — is not overridden.
bool _looksLikeFlattenedTable({
  required String body,
  required String formattedBody,
  required MarkdownComposer composer,
}) {
  final cellTokens = _orderedTableCellTokens(body, composer);
  if (cellTokens == null) return false;
  final htmlTokens = _flattenedHtmlText(
    formattedBody,
  ).split(' ').where((token) => token.isNotEmpty).toList();
  return _containsTokenSequence(htmlTokens, cellTokens);
}

bool _containsTokenSequence(List<String> haystack, List<String> needle) {
  if (needle.isEmpty || needle.length > haystack.length) return false;

  // Remote messages are untrusted and this runs while building a bubble.
  // Use KMP so repeated tokens cannot turn table recovery quadratic.
  final prefixLengths = List<int>.filled(needle.length, 0);
  for (var i = 1, matched = 0; i < needle.length; i++) {
    while (matched > 0 && needle[i] != needle[matched]) {
      matched = prefixLengths[matched - 1];
    }
    if (needle[i] == needle[matched]) matched++;
    prefixLengths[i] = matched;
  }

  for (var matched = 0, i = 0; i < haystack.length; i++) {
    while (matched > 0 && haystack[i] != needle[matched]) {
      matched = prefixLengths[matched - 1];
    }
    if (haystack[i] == needle[matched]) matched++;
    if (matched == needle.length) return true;
  }
  return false;
}

/// All cells of the first markdown table in [body] (header and data rows),
/// in order, as a flat list of whitespace-separated tokens. Cells are
/// taken from the `markdown` package AST, so escaped pipes (`\|`), links
/// and code spans inside cells are handled correctly, and images
/// contribute their alt text. Returns null when there is no table or the
/// table has no text cells.
List<String>? _orderedTableCellTokens(String body, MarkdownComposer composer) {
  final nodes = composer._newDocument().parse(body);
  md.Element? table;
  for (final node in nodes) {
    if (node is md.Element && node.tag == 'table') {
      table = node;
      break;
    }
  }
  if (table == null) return null;
  final cells = <String>[];
  void collectCells(md.Node node) {
    if (node is! md.Element) return;
    if (node.tag == 'th' || node.tag == 'td') {
      final text = _visibleMarkdownText(
        node.children,
      ).replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isNotEmpty) cells.add(text);
      return;
    }
    for (final child in node.children ?? const <md.Node>[]) {
      collectCells(child);
    }
  }

  collectCells(table);
  if (cells.isEmpty) return null;
  return cells.join(' ').split(' ');
}

/// The visible text content of [htmlSource] with separators inserted at
/// block boundaries (`Element.text` alone would concatenate adjacent
/// blocks like `<p>a</p><p>b</p>` into `ab`, hiding the flattened-table
/// shape). Images contribute their alt text, mirroring how
/// `MatrixHtmlParser` treats `<img>` nodes.
String _flattenedHtmlText(String htmlSource) {
  const blockTags = {
    'p',
    'div',
    'br',
    'hr',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'blockquote',
    'ul',
    'ol',
    'li',
    'pre',
    'table',
    'thead',
    'tbody',
    'tr',
    'th',
    'td',
    'caption',
  };
  final root = html_parser.parse(htmlSource).documentElement;
  if (root == null) return '';
  final buffer = StringBuffer();
  void walk(dom.Node node) {
    if (node is dom.Text) {
      buffer.write(node.data);
      return;
    }
    if (node is! dom.Element) return;
    if (node.localName == 'img') {
      // No separators: mirrors `MatrixHtmlParser`, which treats alt as
      // inline visible text. Block-level elements add their own spaces.
      buffer.write(node.attributes['alt'] ?? '');
      return;
    }
    final isBlock = blockTags.contains(node.localName);
    if (isBlock) buffer.write(' ');
    for (final child in node.nodes) {
      walk(child);
    }
    if (isBlock) buffer.write(' ');
  }

  walk(root);
  return buffer.toString().replaceAll(RegExp(r'\s+'), ' ');
}

String? safeMatrixHtmlHref(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  final uri = Uri.tryParse(value.trim());
  if (uri == null) return null;
  if (!const {'http', 'https', 'mailto', 'matrix'}.contains(uri.scheme)) {
    return null;
  }
  return uri.toString();
}

/// Like [safeMatrixHtmlHref] but for image sources, which additionally may
/// be `mxc://` URIs (resolved to authenticated HTTP media at render time).
String? safeMatrixHtmlImgSrc(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  final uri = Uri.tryParse(value.trim());
  if (uri == null) return null;
  if (!const {'http', 'https', 'mxc'}.contains(uri.scheme)) return null;
  return uri.toString();
}

/// A whitelisted `align` attribute value, or null for anything else.
String? safeMatrixHtmlAlign(String? value) {
  const allowed = {'left', 'center', 'right', 'justify'};
  final normalized = value?.trim().toLowerCase();
  return allowed.contains(normalized) ? normalized : null;
}

String? _safeHref(String? value) => safeMatrixHtmlHref(value);

String _escapeAttribute(String value) =>
    const HtmlEscape(HtmlEscapeMode.attribute).convert(value);
