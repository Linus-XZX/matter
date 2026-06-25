import 'dart:convert';

import 'package:markdown/markdown.dart' as md;

import '../../src/rust/api/matrix.dart' as rust;

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
    final formattedBody = (source == body && mentions.isEmpty) || html.isEmpty
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
    blockSyntaxes: const [
      md.FencedCodeBlockSyntax(),
      md.EmptyBlockSyntax(),
      md.SetextHeaderSyntax(),
      md.HeaderSyntax(),
      md.CodeBlockSyntax(),
      md.BlockquoteSyntax(),
      md.HorizontalRuleSyntax(),
      md.UnorderedListSyntax(),
      md.OrderedListSyntax(),
      md.LinkReferenceDefinitionSyntax(),
      md.ParagraphSyntax(),
    ],
    inlineSyntaxes: [md.StrikethroughSyntax(), md.AutolinkExtensionSyntax()],
    extensionSet: md.ExtensionSet.none,
    withDefaultBlockSyntaxes: false,
    encodeHtml: false,
  );
}

class _MatrixMarkdownHtmlRenderer {
  static const _escape = HtmlEscape(HtmlEscapeMode.element);
  final Set<String> mentions;
  bool mentionsRoom = false;

  _MatrixMarkdownHtmlRenderer(this.mentions);

  String render(List<md.Node> nodes) => nodes
      .map((node) => _renderNode(node))
      .where((part) => part.isNotEmpty)
      .join();

  String _renderNode(md.Node node, {bool inCode = false, bool inLink = false}) {
    if (node is md.Text) {
      if (!inCode &&
          RegExp(
            r'(^|\s)@room(?=\s|$|[.,!?;:，。！？；：])',
            multiLine: true,
          ).hasMatch(node.text)) {
        mentionsRoom = true;
      }
      if (!inCode && !inLink) return _renderTextWithMentions(node.text);
      return _escape.convert(node.text);
    }
    if (node is! md.Element) return '';

    final nextInCode = inCode || node.tag == 'code' || node.tag == 'pre';
    final nextInLink = inLink || node.tag == 'a';
    final children =
        node.children
            ?.map(
              (child) =>
                  _renderNode(child, inCode: nextInCode, inLink: nextInLink),
            )
            .join() ??
        '';
    switch (node.tag) {
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
        final userId = _matrixUserIdFromHref(href);
        if (userId != null) mentions.add(userId);
        return '<a href="${_escapeAttribute(href)}">$children</a>';
      case 'br':
        return '<br>';
      case 'hr':
        return '<hr>';
      case 'img':
        return _escape.convert(node.attributes['alt'] ?? '');
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
      case 'pre':
        return node.textContent;
      case 'hr':
        return '---';
      default:
        return _inline(node.children);
    }
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
    final parts = <String>[];
    for (final child in item.children ?? const <md.Node>[]) {
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

  String _inline(List<md.Node>? nodes) {
    if (nodes == null) return '';
    final buffer = StringBuffer();
    for (final node in nodes) {
      if (node is md.Text) {
        buffer.write(node.text);
      } else if (node is md.Element) {
        if (node.tag == 'br') {
          buffer.write('\n');
        } else {
          buffer.write(_inline(node.children));
        }
      }
    }
    return buffer.toString();
  }
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

String? _safeHref(String? value) => safeMatrixHtmlHref(value);

String _escapeAttribute(String value) =>
    const HtmlEscape(HtmlEscapeMode.attribute).convert(value);

String? _matrixUserIdFromHref(String href) {
  final uri = Uri.tryParse(href);
  if (uri == null || uri.host.toLowerCase() != 'matrix.to') return null;
  final target = Uri.decodeComponent(
    uri.fragment,
  ).replaceFirst(RegExp(r'^/'), '');
  if (!RegExp(r'^@[^\s:]+:[^\s:]+$').hasMatch(target)) return null;
  return target;
}
