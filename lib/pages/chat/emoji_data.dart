/// Built-in emoji dataset for the reaction picker.
///
/// Pure-Dart (no native plugin) to avoid the Kotlin Gradle Plugin warning and
/// future incompatibility with Flutter's Built-in Kotlin. The set is a curated
/// subset covering the categories users most want for message reactions and
/// quick replies; it is intentionally finite (no per-codepoint skin-tone
/// matrix) to keep the payload small.
library;

class EmojiCategoryData {
  final String label;
  final String icon;
  final List<String> emojis;
  const EmojiCategoryData({
    required this.label,
    required this.icon,
    required this.emojis,
  });
}

/// Curated emoji set grouped by category. Each list is a single-line string of
/// grapheme clusters; split with `String.runes`/`characters` handled by the
/// caller via `characters` (package:characters) — here we store them as a list
/// of ready-to-use strings so no grapheme splitting is needed.
const List<EmojiCategoryData> kEmojiCategories = [
  EmojiCategoryData(
    label: '常用',
    icon: '⭐️',
    emojis: [
      '👍', '❤️', '😂', '😮', '😢', '🙏', '🔥', '🎉',
      '👏', '🤔', '😎', '🥰', '😅', '😭', '👀', '💪',
      '✅', '❌', '💯', '✨', '🙌', '🤝', '😘', '😴',
    ],
  ),
  EmojiCategoryData(
    label: '表情',
    icon: '😀',
    emojis: [
      '😀', '😃', '😄', '😁', '😆', '😅', '🤣', '😂',
      '🙂', '🙃', '😉', '😊', '😇', '🥰', '😍', '🤩',
      '😘', '😗', '😚', '😙', '😋', '😛', '😜', '🤪',
      '😝', '🤑', '🤗', '🤭', '🤫', '🤔', '🤐', '🤨',
      '😐', '😑', '😶', '😏', '😒', '🙄', '😬', '😮',
      '😯', '😪', '😴', '🤤', '😷', '🤒', '🤕', '🤢',
      '🤮', '🥵', '🥶', '😵', '🤯', '🤠', '🥳', '😎',
      '🤓', '🧐', '😕', '😟', '🙁', '😮', '😯', '😲',
      '😳', '🥺', '😦', '😧', '😨', '😰', '😥', '😢',
      '😭', '😱', '😖', '😣', '😞', '😓', '😩', '😫',
      '😡', '😠', '🤬', '😈', '👿', '💀', '💩', '🤡',
    ],
  ),
  EmojiCategoryData(
    label: '手势',
    icon: '👋',
    emojis: [
      '👋', '🤚', '🖐', '✋', '🖖', '👌', '🤌', '🤏',
      '✌️', '🤞', '🤟', '🤘', '🤙', '👈', '👉', '👆',
      '🖕', '👇', '☝️', '👍', '👎', '✊', '👊', '🤛',
      '🤜', '👏', '🙌', '👐', '🤲', '🤝', '🙏', '💪',
    ],
  ),
  EmojiCategoryData(
    label: '动物',
    icon: '🐶',
    emojis: [
      '🐶', '🐱', '🐭', '🐹', '🐰', '🦊', '🐻', '🐼',
      '🐨', '🐯', '🦁', '🐮', '🐷', '🐸', '🐵', '🐔',
      '🐧', '🐦', '🐤', '🦆', '🦅', '🦉', '🦇', '🐺',
      '🐗', '🐴', '🦄', '🐝', '🐛', '🦋', '🐌', '🐞',
      '🐙', '🦑', '🦐', '🦀', '🐡', '🐠', '🐟', '🐬',
      '🐳', '🐋', '🦈', '🐊', '🐅', '🐆', '🦓', '🦍',
    ],
  ),
  EmojiCategoryData(
    label: '食物',
    icon: '🍔',
    emojis: [
      '🍏', '🍎', '🍐', '🍊', '🍋', '🍌', '🍉', '🍇',
      '🍓', '🫐', '🍈', '🍒', '🍑', '🥭', '🍍', '🥥',
      '🥝', '🍅', '🍔', '🍟', '🍕', '🌭', '🥪', '🌮',
      '🌯', '🥙', '🍜', '🍲', '🍛', '🍣', '🍱', '🥟',
      '🦪', '🍦', '🍩', '🍪', '🎂', '🍰', '🧁', '🍫',
      '🍬', '🍭', '🍮', '🍯', '☕️', '🍵', '🍶', '🍺',
    ],
  ),
  EmojiCategoryData(
    label: '活动',
    icon: '⚽️',
    emojis: [
      '⚽️', '🏀', '🏈', '⚾️', '🥎', '🎾', '🏐', '🏉',
      '🥏', '🎱', '🪀', '🏓', '🏸', '🏒', '🏑', '🥍',
      '🏏', '⛳️', '🏹', '🎣', '🥊', '🥋', '🎽', '⛸',
      '🥌', '🛷', '🎿', '⛷', '🏂', '🪂', '🏆', '🥇',
      '🥈', '🥉', '🏅', '🎖', '🎗', '🎵', '🎶', '🎤',
      '🎧', '🎷', '🎸', '🎹', '🎺', '🎻', '🥁', '🎯',
    ],
  ),
  EmojiCategoryData(
    label: '物品',
    icon: '💡',
    emojis: [
      '⌚️', '📱', '💻', '⌨️', '🖥', '🖨', '🖱', '💽',
      '💾', '💿', '📷', '📸', '📹', '🎥', '📞', '☎️',
      '📺', '📻', '⏰', '🕰', '💡', '🔦', '📖', '📚',
      '✏️', '🖊', '🖋', '🖌', '📝', '💼', '📁', '📌',
      '📎', '✂️', '📐', '📏', '🔧', '🔨', '🛠', '💎',
      '🔑', '🔒', '🔔', '🎁', '🎈', '🎉', '🎊', '🎀',
    ],
  ),
  EmojiCategoryData(
    label: '符号',
    icon: '❤️',
    emojis: [
      '❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍',
      '🤎', '💔', '❣️', '💕', '💞', '💓', '💗', '💖',
      '💘', '💝', '💟', '✅', '❌', '❎', '✔️', '➕',
      '➖', '➗', '✖️', '♾', '‼️', '⁉️', '❓', '❗️',
      '🔴', '🟠', '🟡', '🟢', '🔵', '🟣', '⚫️', '⚪️',
      '🟥', '🟧', '🟨', '🟩', '🟦', '🟪', '⬛️', '⬜️',
      '⭐️', '🌟', '✨', '⚡️', '🔥', '💯', '💢', '💤',
    ],
  ),
];
