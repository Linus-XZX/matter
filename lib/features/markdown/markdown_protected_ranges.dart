import 'package:flutter/services.dart';

final _markdownPunctuation = RegExp(
  r'''[!"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~\u2000-\u206f\u3000-\u303f\uff01-\uff0f\uff1a-\uff20\uff3b-\uff40\uff5b-\uff65]''',
  unicode: true,
);

bool markdownDelimiterCanOpen(String source, int start, int end) {
  final precededByWhitespace = start == 0 || source[start - 1].trim().isEmpty;
  final followedByWhitespace =
      end == source.length || source[end].trim().isEmpty;
  final precededByPunctuation =
      start > 0 && _markdownPunctuation.hasMatch(source[start - 1]);
  final followedByPunctuation =
      end < source.length && _markdownPunctuation.hasMatch(source[end]);
  return !followedByWhitespace &&
      (!followedByPunctuation || precededByWhitespace || precededByPunctuation);
}

bool markdownDelimiterCanClose(String source, int start, int end) {
  final precededByWhitespace = start == 0 || source[start - 1].trim().isEmpty;
  final followedByWhitespace =
      end == source.length || source[end].trim().isEmpty;
  final precededByPunctuation =
      start > 0 && _markdownPunctuation.hasMatch(source[start - 1]);
  final followedByPunctuation =
      end < source.length && _markdownPunctuation.hasMatch(source[end]);
  return !precededByWhitespace &&
      (!precededByPunctuation || followedByWhitespace || followedByPunctuation);
}

/// Source ranges where inline format markers are literal rather than markup.
List<TextRange> markdownProtectedRanges(String source) {
  final ranges = <TextRange>[];
  var index = 0;
  while (index < source.length) {
    final fencedEnd = _fencedCodeEnd(source, index);
    if (fencedEnd != null) {
      ranges.add(TextRange(start: index, end: fencedEnd));
      index = fencedEnd;
      continue;
    }

    if (source[index] == '`') {
      final codeEnd = _inlineCodeEnd(source, index);
      if (codeEnd != null) {
        ranges.add(TextRange(start: index, end: codeEnd));
        index = codeEnd;
        continue;
      }
    }

    if (source[index] == '(' && index > 0 && source[index - 1] == ']') {
      final destinationEnd = _linkDestinationEnd(source, index);
      if (destinationEnd != null) {
        ranges.add(TextRange(start: index, end: destinationEnd));
        index = destinationEnd;
        continue;
      }
    }

    if (source[index] == '<') {
      final close = source.indexOf('>', index + 1);
      if (close >= 0) {
        final inner = source.substring(index + 1, close);
        if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(inner) ||
            (inner.contains('@') && !inner.contains(' '))) {
          ranges.add(TextRange(start: index, end: close + 1));
          index = close + 1;
          continue;
        }
      }
    }
    index++;
  }
  return ranges;
}

int? _fencedCodeEnd(String source, int start) {
  final marker = source[start];
  if (marker != '`' && marker != '~') return null;
  final lineStart = start == 0 ? 0 : source.lastIndexOf('\n', start - 1) + 1;
  final indent = source.substring(lineStart, start);
  if (indent.length > 3 || indent.trim().isNotEmpty) return null;

  var runLength = 1;
  while (start + runLength < source.length &&
      source[start + runLength] == marker) {
    runLength++;
  }
  if (runLength < 3) return null;

  var nextLine = source.indexOf('\n', start + runLength);
  if (nextLine < 0) return source.length;
  nextLine++;
  while (nextLine < source.length) {
    var candidate = nextLine;
    while (candidate < source.length &&
        candidate - nextLine < 3 &&
        source[candidate] == ' ') {
      candidate++;
    }
    var closeLength = 0;
    while (candidate + closeLength < source.length &&
        source[candidate + closeLength] == marker) {
      closeLength++;
    }
    if (closeLength >= runLength) {
      final lineEnd = source.indexOf('\n', candidate + closeLength);
      final trailingEnd = lineEnd < 0 ? source.length : lineEnd;
      if (source
          .substring(candidate + closeLength, trailingEnd)
          .trim()
          .isEmpty) {
        return lineEnd < 0 ? source.length : lineEnd + 1;
      }
    }
    final lineEnd = source.indexOf('\n', nextLine);
    if (lineEnd < 0) return source.length;
    nextLine = lineEnd + 1;
  }
  return source.length;
}

int? _inlineCodeEnd(String source, int start) {
  var runLength = 1;
  while (start + runLength < source.length &&
      source[start + runLength] == '`') {
    runLength++;
  }
  var index = start + runLength;
  while (index < source.length) {
    if (source[index] != '`') {
      index++;
      continue;
    }
    var closeLength = 1;
    while (index + closeLength < source.length &&
        source[index + closeLength] == '`') {
      closeLength++;
    }
    if (closeLength == runLength && index > start + runLength) {
      return index + runLength;
    }
    index += closeLength;
  }
  return null;
}

int? _linkDestinationEnd(String source, int start) {
  var depth = 1;
  var index = start + 1;
  while (index < source.length) {
    if (source[index] == r'\' && index + 1 < source.length) {
      index += 2;
      continue;
    }
    if (source[index] == '(') depth++;
    if (source[index] == ')' && --depth == 0) return index + 1;
    if (source[index] == '\n') return null;
    index++;
  }
  return null;
}
