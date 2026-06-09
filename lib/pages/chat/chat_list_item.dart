import 'package:flutter/material.dart';
import '../../src/rust/api/matrix.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_avatar.dart';
import 'chat_detail_page.dart';

class ChatListItem extends StatelessWidget {
  final ChatRoom room;

  const ChatListItem({super.key, required this.room});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChatDetailPage(
              roomId: room.id,
              roomName: room.name,
              avatarUrl: room.avatarUrl,
              subtitle: room.unreadCount > 0
                  ? '${room.unreadCount} 条未读消息'
                  : '在线',
            ),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          AppAvatar(
            fallback: room.name,
            size: 52,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        room.name,
                        style: const TextStyle(
                          color: AppColors.onBackground,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      room.lastMessageTime,
                      style: TextStyle(
                        color: room.unreadCount > 0
                            ? AppColors.primary
                            : AppColors.onSurfaceVariant,
                        fontSize: 12,
                        fontWeight: room.unreadCount > 0
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    if (room.isMuted)
                      const Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: Icon(
                          Icons.notifications_off_rounded,
                          color: AppColors.onSurfaceVariant,
                          size: 14,
                        ),
                      ),
                    if (room.isPinned)
                      const Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: Icon(
                          Icons.push_pin_rounded,
                          color: AppColors.onSurfaceVariant,
                          size: 14,
                        ),
                      ),
                    Expanded(
                      child: Text(
                        room.lastMessage,
                        style: const TextStyle(
                          color: AppColors.onSurfaceVariant,
                          fontSize: 14,
                          height: 1.3,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (room.unreadCount > 0) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: room.isMuted
                              ? AppColors.surfaceElevated
                              : AppColors.primary,
                          borderRadius: BorderRadius.circular(AppRadii.tag),
                        ),
                        child: Text(
                          room.unreadCount > 99 ? '99+' : '${room.unreadCount}',
                          style: TextStyle(
                            color: room.isMuted
                                ? AppColors.onSurfaceVariant
                                : Colors.white,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }
}
