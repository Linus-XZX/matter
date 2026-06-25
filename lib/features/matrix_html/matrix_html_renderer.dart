import 'package:flutter/material.dart';

import 'matrix_html_node.dart';
import 'matrix_html_parser.dart';
import 'matrix_link_router.dart';

class MatrixHtmlMessage extends StatefulWidget {
  final String html;
  final TextStyle style;
  final Color accentColor;
  final MatrixLinkHandler? onLinkTap;

  const MatrixHtmlMessage({
    super.key,
    required this.html,
    required this.style,
    required this.accentColor,
    this.onLinkTap,
  });

  @override
  State<MatrixHtmlMessage> createState() => _MatrixHtmlMessageState();
}

class _MatrixHtmlMessageState extends State<MatrixHtmlMessage> {
  static const _parser = MatrixHtmlParser();
  late List<MatrixHtmlNode> _nodes;

  @override
  void initState() {
    super.initState();
    _nodes = _parser.parse(widget.html);
  }

  @override
  void didUpdateWidget(covariant MatrixHtmlMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html) {
      _nodes = _parser.parse(widget.html);
    }
  }

  @override
  Widget build(BuildContext context) {
    final renderer = _MatrixNodeRenderer(
      context: context,
      baseStyle: widget.style,
      accentColor: widget.accentColor,
      onLinkTap: widget.onLinkTap ?? const MatrixLinkRouter().open,
    );
    final blocks = renderer.renderBlocks(_nodes);
    if (blocks.isEmpty) return const SizedBox.shrink();
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: blocks,
      ),
    );
  }
}

class _MatrixNodeRenderer {
  final BuildContext context;
  final TextStyle baseStyle;
  final Color accentColor;
  final MatrixLinkHandler onLinkTap;

  const _MatrixNodeRenderer({
    required this.context,
    required this.baseStyle,
    required this.accentColor,
    required this.onLinkTap,
  });

  List<Widget> renderBlocks(List<MatrixHtmlNode> nodes) {
    final widgets = <Widget>[];
    for (final node in nodes) {
      final widget = _renderBlock(node);
      if (widget == null) continue;
      if (widgets.isNotEmpty) widgets.add(const SizedBox(height: 7));
      widgets.add(widget);
    }
    return widgets;
  }

  Widget? _renderBlock(MatrixHtmlNode node) {
    if (node is MatrixTextNode) {
      if (node.text.trim().isEmpty) return null;
      return _richText([node], baseStyle);
    }
    final element = node as MatrixElementNode;
    switch (element.tag) {
      case 'p':
        return _richText(element.children, baseStyle);
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        final level = int.parse(element.tag.substring(1));
        return _richText(
          element.children,
          baseStyle.copyWith(
            fontSize: (22 - level * 1.5).clamp(15, 21).toDouble(),
            fontWeight: FontWeight.w800,
            height: 1.25,
          ),
        );
      case 'blockquote':
        return Container(
          padding: const EdgeInsets.only(left: 10, top: 3, bottom: 3),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: accentColor, width: 3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: renderBlocks(element.children),
          ),
        );
      case 'ul':
      case 'ol':
        return _renderList(element, ordered: element.tag == 'ol');
      case 'pre':
        return Container(
          constraints: const BoxConstraints(maxWidth: 520),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(8),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(
              element.textContent,
              style: baseStyle.copyWith(
                fontFamily: 'monospace',
                fontSize: baseStyle.fontSize == null
                    ? 13
                    : baseStyle.fontSize! - 1,
              ),
            ),
          ),
        );
      case 'hr':
        return Divider(color: baseStyle.color?.withValues(alpha: 0.3));
      default:
        return _richText([element], baseStyle);
    }
  }

  Widget _renderList(MatrixElementNode list, {required bool ordered}) {
    final items = list.children.whereType<MatrixElementNode>().where(
      (node) => node.tag == 'li',
    );
    final start = int.tryParse(list.attributes['start'] ?? '') ?? 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in items.indexed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 24,
                  child: Text(
                    ordered ? '${start + entry.$1}.' : '•',
                    textAlign: TextAlign.right,
                    style: baseStyle.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: renderBlocks(entry.$2.children),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _richText(List<MatrixHtmlNode> nodes, TextStyle style) {
    return Text.rich(
      TextSpan(style: style, children: _inlineSpans(nodes, style)),
      softWrap: true,
    );
  }

  List<InlineSpan> _inlineSpans(
    List<MatrixHtmlNode> nodes,
    TextStyle inherited,
  ) {
    final spans = <InlineSpan>[];
    for (final node in nodes) {
      if (node is MatrixTextNode) {
        spans.add(TextSpan(text: node.text, style: inherited));
        continue;
      }
      final element = node as MatrixElementNode;
      var style = inherited;
      if (element.tag == 'strong' || element.tag == 'b') {
        style = style.copyWith(fontWeight: FontWeight.w800);
      } else if (element.tag == 'em' || element.tag == 'i') {
        style = style.copyWith(fontStyle: FontStyle.italic);
      } else if (element.tag == 'del' || element.tag == 's') {
        style = style.copyWith(decoration: TextDecoration.lineThrough);
      } else if (element.tag == 'code') {
        style = style.copyWith(
          fontFamily: 'monospace',
          backgroundColor: Colors.black.withValues(alpha: 0.14),
        );
      } else if (element.tag == 'br') {
        spans.add(const TextSpan(text: '\n'));
        continue;
      } else if (element.tag == 'a') {
        final href = element.attributes['href'];
        if (href != null) {
          final uri = Uri.tryParse(href);
          final isMention =
              uri?.host.toLowerCase() == 'matrix.to' &&
              Uri.decodeComponent(uri?.fragment ?? '').startsWith('/@');
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: InkWell(
                onTap: uri == null ? null : () => onLinkTap(uri),
                borderRadius: BorderRadius.circular(5),
                child: Text(
                  element.textContent,
                  style: style.copyWith(
                    color: accentColor,
                    fontWeight: isMention ? FontWeight.w800 : FontWeight.w600,
                    decoration: isMention
                        ? TextDecoration.none
                        : TextDecoration.underline,
                    backgroundColor: isMention
                        ? accentColor.withValues(alpha: 0.12)
                        : null,
                  ),
                ),
              ),
            ),
          );
          continue;
        }
      }
      spans.addAll(_inlineSpans(element.children, style));
    }
    return spans;
  }
}
