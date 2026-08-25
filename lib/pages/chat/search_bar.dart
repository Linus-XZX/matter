import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'search_page.dart';

class ChatSearchBar extends StatelessWidget {
  const ChatSearchBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Material(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(AppRadii.surface),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const ValueKey('open-chat-search'),
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const ChatSearchPage())),
          child: const SizedBox(
            height: 44,
            child: Row(
              children: [
                SizedBox(width: 12),
                Icon(
                  Icons.search_rounded,
                  color: AppColors.onSurfaceVariant,
                  size: 20,
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '搜索消息或聊天',
                    style: TextStyle(
                      color: AppColors.onSurfaceVariant,
                      fontSize: 15,
                    ),
                  ),
                ),
                SizedBox(width: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
