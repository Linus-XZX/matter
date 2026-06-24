import 'package:flutter/material.dart';

final RegExp _mentionPattern = RegExp(
  r'(?<![\w@])@[A-Za-z0-9\u3400-\u9FFF._=\-/]+(?::[A-Za-z0-9.-]+)?',
  unicode: true,
);

TextSpan messageTextSpan(
  String text, {
  required TextStyle style,
  required Color mentionColor,
}) {
  final children = <InlineSpan>[];
  var offset = 0;
  for (final match in _mentionPattern.allMatches(text)) {
    if (match.start > offset) {
      children.add(TextSpan(text: text.substring(offset, match.start)));
    }
    children.add(
      TextSpan(
        text: match.group(0),
        style: style.copyWith(
          color: mentionColor,
          fontWeight: FontWeight.w800,
          backgroundColor: mentionColor.withValues(alpha: 0.12),
        ),
      ),
    );
    offset = match.end;
  }
  if (offset < text.length) {
    children.add(TextSpan(text: text.substring(offset)));
  }
  return TextSpan(style: style, children: children);
}
