import 'package:flutter/material.dart';

import '../../features/matrix_html/matrix_html_renderer.dart';
import '../../theme/app_theme.dart';

/// Opens the full-screen reader for a formatted (markdown) message.
void openMessageReader(
  BuildContext context, {
  required String html,
  required Map<String, String> mentionDisplayNames,
  required ValueChanged<String> onMentionTap,
}) {
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => MessageReaderPage(
        html: html,
        mentionDisplayNames: mentionDisplayNames,
        onMentionTap: onMentionTap,
      ),
    ),
  );
}

/// Full-screen reading view for a formatted message. Reuses the same HTML
/// renderer as the bubble (including table recovery), with a comfortable
/// reading width and selectable text.
class MessageReaderPage extends StatelessWidget {
  final String html;
  final Map<String, String> mentionDisplayNames;
  final ValueChanged<String>? onMentionTap;

  const MessageReaderPage({
    super.key,
    required this.html,
    this.mentionDisplayNames = const {},
    this.onMentionTap,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('阅读'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: MatrixHtmlMessage(
                html: html,
                style: const TextStyle(
                  color: AppColors.onBackground,
                  fontSize: 16,
                  height: 1.5,
                ),
                accentColor: AppColors.secondary,
                mentionDisplayNames: mentionDisplayNames,
                onMentionTap: onMentionTap,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
