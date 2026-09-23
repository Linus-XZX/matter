import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

@immutable
class ChatVisualSettings {
  final bool chatBlurEnabled;
  final bool bubbleShadowsEnabled;
  final bool superellipseBorderEnabled;
  final bool bubbleGradientEnabled;
  final bool shortImageBlurredBackdropEnabled;
  final bool stickyAvatarsEnabled;

  const ChatVisualSettings({
    this.chatBlurEnabled = true,
    this.bubbleShadowsEnabled = true,
    this.superellipseBorderEnabled = true,
    this.bubbleGradientEnabled = true,
    this.shortImageBlurredBackdropEnabled = true,
    this.stickyAvatarsEnabled = true,
  });

  ChatVisualSettings copyWith({
    bool? chatBlurEnabled,
    bool? bubbleShadowsEnabled,
    bool? superellipseBorderEnabled,
    bool? bubbleGradientEnabled,
    bool? shortImageBlurredBackdropEnabled,
    bool? stickyAvatarsEnabled,
  }) {
    return ChatVisualSettings(
      chatBlurEnabled: chatBlurEnabled ?? this.chatBlurEnabled,
      bubbleShadowsEnabled: bubbleShadowsEnabled ?? this.bubbleShadowsEnabled,
      superellipseBorderEnabled:
          superellipseBorderEnabled ?? this.superellipseBorderEnabled,
      bubbleGradientEnabled:
          bubbleGradientEnabled ?? this.bubbleGradientEnabled,
      shortImageBlurredBackdropEnabled:
          shortImageBlurredBackdropEnabled ??
          this.shortImageBlurredBackdropEnabled,
      stickyAvatarsEnabled: stickyAvatarsEnabled ?? this.stickyAvatarsEnabled,
    );
  }
}

class ChatVisualSettingsNotifier extends Notifier<ChatVisualSettings> {
  static const _keys = {
    'chatBlurEnabled': 'chat_visual_chat_blur',
    'bubbleShadowsEnabled': 'chat_visual_bubble_shadows',
    'superellipseBorderEnabled': 'chat_visual_superellipse_border',
    'bubbleGradientEnabled': 'chat_visual_bubble_gradient',
    'shortImageBlurredBackdropEnabled': 'chat_visual_short_image_backdrop',
    'stickyAvatarsEnabled': 'chat_visual_sticky_avatars',
  };

  @override
  ChatVisualSettings build() {
    _restore();
    return const ChatVisualSettings();
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final current = state;
    state = current.copyWith(
      chatBlurEnabled: prefs.getBool(_keys['chatBlurEnabled']!) ?? true,
      bubbleShadowsEnabled:
          prefs.getBool(_keys['bubbleShadowsEnabled']!) ?? true,
      superellipseBorderEnabled:
          prefs.getBool(_keys['superellipseBorderEnabled']!) ?? true,
      bubbleGradientEnabled:
          prefs.getBool(_keys['bubbleGradientEnabled']!) ?? true,
      shortImageBlurredBackdropEnabled:
          prefs.getBool(_keys['shortImageBlurredBackdropEnabled']!) ?? true,
      stickyAvatarsEnabled:
          prefs.getBool(_keys['stickyAvatarsEnabled']!) ?? true,
    );
  }

  Future<void> setChatBlurEnabled(bool value) =>
      _set((settings) => settings.copyWith(chatBlurEnabled: value));

  Future<void> setBubbleShadowsEnabled(bool value) =>
      _set((settings) => settings.copyWith(bubbleShadowsEnabled: value));

  Future<void> setSuperellipseBorderEnabled(bool value) =>
      _set((settings) => settings.copyWith(superellipseBorderEnabled: value));

  Future<void> setBubbleGradientEnabled(bool value) =>
      _set((settings) => settings.copyWith(bubbleGradientEnabled: value));

  Future<void> setShortImageBlurredBackdropEnabled(bool value) => _set(
    (settings) => settings.copyWith(shortImageBlurredBackdropEnabled: value),
  );

  Future<void> setStickyAvatarsEnabled(bool value) =>
      _set((settings) => settings.copyWith(stickyAvatarsEnabled: value));

  Future<void> _set(
    ChatVisualSettings Function(ChatVisualSettings) update,
  ) async {
    final next = update(state);
    state = next;
    final prefs = await SharedPreferences.getInstance();
    for (final entry in _keys.entries) {
      final value = switch (entry.key) {
        'chatBlurEnabled' => next.chatBlurEnabled,
        'bubbleShadowsEnabled' => next.bubbleShadowsEnabled,
        'superellipseBorderEnabled' => next.superellipseBorderEnabled,
        'bubbleGradientEnabled' => next.bubbleGradientEnabled,
        'shortImageBlurredBackdropEnabled' =>
          next.shortImageBlurredBackdropEnabled,
        'stickyAvatarsEnabled' => next.stickyAvatarsEnabled,
        _ => true,
      };
      await prefs.setBool(entry.value, value);
    }
  }
}

final chatVisualSettingsProvider =
    NotifierProvider<ChatVisualSettingsNotifier, ChatVisualSettings>(
      ChatVisualSettingsNotifier.new,
    );

class ChatVisualSettingsScope extends InheritedWidget {
  final ChatVisualSettings settings;

  const ChatVisualSettingsScope({
    super.key,
    required this.settings,
    required super.child,
  });

  static ChatVisualSettings of(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<ChatVisualSettingsScope>()
            ?.settings ??
        const ChatVisualSettings();
  }

  static ChatVisualSettings? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<ChatVisualSettingsScope>()
        ?.settings;
  }

  @override
  bool updateShouldNotify(ChatVisualSettingsScope oldWidget) =>
      settings != oldWidget.settings;
}
