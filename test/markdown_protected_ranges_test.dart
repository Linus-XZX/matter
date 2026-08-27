import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/markdown/markdown_protected_ranges.dart';

void main() {
  test('finds inline and fenced code ranges', () {
    const source = '`**inline**`\n~~~dart\n**fenced**\n~~~\nafter';
    final ranges = markdownProtectedRanges(source);
    expect(ranges.map((range) => range.textInside(source)), [
      '`**inline**`',
      '~~~dart\n**fenced**\n~~~\n',
    ]);
  });

  test('finds link destinations and autolinks', () {
    const source = '[label](https://host/**path**) <https://host/**path**>';
    final ranges = markdownProtectedRanges(source);
    expect(ranges.map((range) => range.textInside(source)), [
      '(https://host/**path**)',
      '<https://host/**path**>',
    ]);
  });
}
