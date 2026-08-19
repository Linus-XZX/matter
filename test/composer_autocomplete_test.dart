import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/composer_autocomplete.dart';

void main() {
  group('composerAutocompleteMatch', () {
    test('finds the token at the collapsed cursor', () {
      const value = TextEditingValue(
        text: 'hello @ali',
        selection: TextSelection.collapsed(offset: 10),
      );

      expect(
        composerAutocompleteMatch(value),
        const ComposerAutocompleteMatch(
          kind: ComposerAutocompleteKind.mention,
          start: 6,
          end: 10,
          query: 'ali',
        ),
      );
    });

    test('keeps a closing emoji colon in the replacement range', () {
      const value = TextEditingValue(
        text: 'hmm :thinking:',
        selection: TextSelection.collapsed(offset: 14),
      );

      expect(
        composerAutocompleteMatch(value),
        const ComposerAutocompleteMatch(
          kind: ComposerAutocompleteKind.emoji,
          start: 4,
          end: 14,
          query: 'thinking',
        ),
      );
    });

    test('does not trigger inside ordinary words or times', () {
      for (final text in ['mail@example.org', '12:30']) {
        expect(
          composerAutocompleteMatch(
            TextEditingValue(
              text: text,
              selection: TextSelection.collapsed(offset: text.length),
            ),
          ),
          isNull,
        );
      }
    });

    test('includes the rest of a token after the cursor', () {
      const value = TextEditingValue(
        text: 'hello @alice.smith world',
        selection: TextSelection.collapsed(offset: 10),
      );

      expect(
        composerAutocompleteMatch(value),
        const ComposerAutocompleteMatch(
          kind: ComposerAutocompleteKind.mention,
          start: 6,
          end: 18,
          query: 'ali',
        ),
      );
    });
  });

  test('applyComposerAutocomplete only replaces the active token', () {
    const value = TextEditingValue(
      text: 'ask :thinking: later',
      selection: TextSelection.collapsed(offset: 14),
    );
    final match = composerAutocompleteMatch(value)!;

    expect(
      applyComposerAutocomplete(value, match, '🤔'),
      const TextEditingValue(
        text: 'ask 🤔 later',
        selection: TextSelection.collapsed(offset: 6),
      ),
    );
  });

  test('emoji names include the thinking shortcode', () {
    final options = emojiAutocompleteOptions('thinking');

    expect(options.first.emoji, '🤔');
    expect(options.first.name, 'thinking');
  });

  test('replacement reuses an existing separator after the token', () {
    for (final separator in [', now', '. Next']) {
      final value = TextEditingValue(
        text: 'see #gen$separator',
        selection: const TextSelection.collapsed(offset: 8),
      );
      final match = composerAutocompleteMatch(value)!;

      expect(
        applyComposerAutocomplete(value, match, '#General '),
        TextEditingValue(
          text: 'see #General$separator',
          selection: const TextSelection.collapsed(offset: 12),
        ),
      );
    }
  });
}
