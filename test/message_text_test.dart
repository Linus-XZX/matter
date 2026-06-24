import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/message_text.dart';

void main() {
  test('message mentions are rendered with a distinct emphasized style', () {
    const base = TextStyle(color: Colors.white, fontSize: 15);
    final span = messageTextSpan(
      '你好 @alice:example.org、@bob 和 @小明',
      style: base,
      mentionColor: Colors.cyan,
    );
    final mentions = span.children!
        .whereType<TextSpan>()
        .where((child) => child.text?.startsWith('@') == true)
        .toList();

    expect(mentions.map((span) => span.text), [
      '@alice:example.org',
      '@bob',
      '@小明',
    ]);
    expect(mentions.every((span) => span.style?.color == Colors.cyan), isTrue);
    expect(
      mentions.every((span) => span.style?.fontWeight == FontWeight.w800),
      isTrue,
    );
  });
}
