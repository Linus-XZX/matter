import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_avatar.dart';
import 'chat_timestamp.dart';
import 'chat_detail_page.dart';
import 'message_input.dart';
import 'space_detail_page.dart';

String chatListPreview(ChatRoom room) {
  if (room.roomState == 'invited') {
    return '邀请你加入';
  }
  if (room.roomState == 'knocked') {
    return '等待对方批准';
  }
  final sender = room.lastMessageSender?.trim();
  if (room.roomType != 'group' ||
      sender == null ||
      sender.isEmpty ||
      room.lastMessage.isEmpty) {
    return room.lastMessage;
  }
  return '$sender：${room.lastMessage}';
}

class ChatListItem extends ConsumerWidget {
  final ChatRoom room;
  final bool dense;
  final bool showRoomTypeIcon;
  final ValueChanged<ChatRoom>? onRoomSelected;
  final bool isSelected;

  const ChatListItem({
    super.key,
    required this.room,
    this.dense = false,
    this.showRoomTypeIcon = true,
    this.onRoomSelected,
    this.isSelected = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final room = this.room;
    final isPendingMembership =
        room.roomState == 'invited' || room.roomState == 'knocked';
    final userId =
        ref.watch(activeUserIdProvider) ??
        ref.watch(currentUserProvider.select((user) => user?.id)) ??
        'anonymous';
    final draft = ref.watch(
      messageDraftProvider((roomId: room.id, userId: userId)),
    );
    final hasDraft =
        room.roomState == 'joined' &&
        room.roomType != 'space' &&
        draft.trim().isNotEmpty;
    final preview = hasDraft
        ? draft.trim().replaceAll(RegExp(r'\s+'), ' ')
        : chatListPreview(room);
    final unreadOverride = ref.watch(roomUnreadOverrideProvider(room.id));
    final syncedHasUnread = room.unreadCount > 0 || room.isMarkedUnread;
    final overrideApplies = unreadOverride?.appliesTo(room) ?? false;
    final hasUnread = overrideApplies
        ? unreadOverride!.unread
        : syncedHasUnread;
    final unreadAccent = room.isMuted
        ? AppColors.onSurfaceVariant
        : AppColors.primary;
    if (unreadOverride != null && !overrideApplies) {
      Future.microtask(() {
        if (!context.mounted) return;
        if (identical(
          ref.read(roomUnreadOverrideProvider(room.id)),
          unreadOverride,
        )) {
          ref.read(roomUnreadOverrideProvider(room.id).notifier).value = null;
        }
      });
    }

    return InkWell(
      borderRadius: BorderRadius.circular(AppRadii.button),
      onTap: () {
        if (isPendingMembership) return;
        if (onRoomSelected case final onRoomSelected?) {
          onRoomSelected(room);
          return;
        }
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => room.roomType == 'space'
                ? SpaceDetailPage(
                    space: Space(
                      id: room.id,
                      name: room.name,
                      avatarUrl: room.avatarUrl,
                    ),
                  )
                : ChatDetailPage(
                    roomId: room.id,
                    roomName: room.name,
                    avatarUrl: room.avatarUrl,
                    nameEventId: room.nameEventId,
                    avatarEventId: room.avatarEventId,
                    isDm: room.roomType == 'dm',
                    subtitle: room.unreadCount > 0
                        ? '${room.unreadCount} 条未读消息'
                        : '在线',
                  ),
          ),
        );
      },
      onLongPress: room.roomState == 'joined' && room.roomType != 'space'
          ? () => _showRoomListActions(context, ref, room)
          : null,
      child: Container(
        margin: onRoomSelected != null
            ? const EdgeInsets.symmetric(horizontal: 8)
            : null,
        padding: EdgeInsets.symmetric(
          horizontal: onRoomSelected != null ? 12 : 16,
          vertical: dense ? 6 : 8,
        ),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.surfaceVariant : null,
          borderRadius: BorderRadius.circular(AppRadii.button),
        ),
        child: Row(
          children: [
            AppAvatar(
              key: ValueKey('room-avatar:${room.id}:${room.avatarUrl}'),
              fallback: room.name,
              size: dense ? 44 : 52,
              url: room.avatarUrl,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (showRoomTypeIcon) ...[
                        _roomTypeIcon(room.roomType),
                        const SizedBox(width: 4),
                      ],
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
                      if (room.isMuted) ...[
                        const SizedBox(width: 6),
                        Icon(
                          Icons.volume_off_rounded,
                          key: ValueKey('room-muted-icon:${room.id}'),
                          size: 15,
                          color: AppColors.onSurfaceVariant,
                        ),
                      ],
                      const SizedBox(width: 8),
                      Text(
                        formatChatListTime(room.lastMessageTime),
                        style: TextStyle(
                          color: hasUnread
                              ? unreadAccent
                              : AppColors.onSurfaceVariant,
                          fontSize: 12,
                          fontWeight: hasUnread
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              if (hasDraft)
                                const TextSpan(
                                  text: '草稿：',
                                  style: TextStyle(
                                    color: AppColors.error,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              TextSpan(text: preview),
                            ],
                          ),
                          style: const TextStyle(
                            color: AppColors.onSurfaceVariant,
                            fontSize: 13.5,
                            height: 1.3,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (hasUnread) ...[
                        const SizedBox(width: 8),
                        if (room.unreadCount > 0)
                          Container(
                            key: ValueKey('room-unread-badge:${room.id}'),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: unreadAccent,
                              borderRadius: BorderRadius.circular(AppRadii.tag),
                            ),
                            child: Text(
                              room.unreadCount > 99
                                  ? '99+'
                                  : '${room.unreadCount}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          )
                        else
                          Container(
                            key: ValueKey('room-unread-dot:${room.id}'),
                            width: 9,
                            height: 9,
                            decoration: BoxDecoration(
                              color: unreadAccent,
                              shape: BoxShape.circle,
                            ),
                          ),
                      ],
                    ],
                  ),
                  if (isPendingMembership) ...[
                    const SizedBox(height: 8),
                    _PendingRoomActions(room: room),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _roomTypeIcon(String roomType) {
    return switch (roomType) {
      'dm' => const Icon(
        Icons.person_rounded,
        size: 14,
        color: AppColors.primary,
      ),
      'space' => const Icon(
        Icons.account_tree_rounded,
        size: 14,
        color: AppColors.secondary,
      ),
      _ => const Icon(
        Icons.group_rounded,
        size: 14,
        color: AppColors.onSurfaceVariant,
      ),
    };
  }

  void _showRoomListActions(
    BuildContext context,
    WidgetRef ref,
    ChatRoom room,
  ) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Container(
        margin: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadii.surface),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(
                  Icons.done_all_rounded,
                  color: AppColors.primary,
                ),
                title: const Text(
                  '标记为已读',
                  style: TextStyle(color: AppColors.onBackground),
                ),
                onTap: () => _runRoomListAction(
                  context,
                  sheetContext,
                  ref,
                  room,
                  markRoomAsRead,
                  false,
                  '已标记为已读',
                ),
              ),
              ListTile(
                leading: const Icon(
                  Icons.mark_unread_chat_alt_rounded,
                  color: AppColors.primary,
                ),
                title: const Text(
                  '标记为未读',
                  style: TextStyle(color: AppColors.onBackground),
                ),
                onTap: () => _runRoomListAction(
                  context,
                  sheetContext,
                  ref,
                  room,
                  markRoomUnread,
                  true,
                  '已标记为未读',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _runRoomListAction(
    BuildContext context,
    BuildContext sheetContext,
    WidgetRef ref,
    ChatRoom room,
    Future<void> Function({required String roomId}) action,
    bool markedUnread,
    String successMessage,
  ) async {
    final suppression = roomAutoReadSuppressedProvider(room.id);
    final suppressionNotifier = ref.read(suppression.notifier);
    final previousSuppression = suppressionNotifier.value;
    final suppressionToken = setRoomAutoReadSuppressed(
      ref,
      room.id,
      suppressed: markedUnread,
    );
    try {
      await action(roomId: room.id);
      if (!context.mounted || !suppressionToken.isCurrent) {
        return;
      }
      setRoomUnreadOverride(ref, room, unread: markedUnread);
      ref.invalidate(chatRoomsProvider);
      ref.invalidate(ungroupedRoomsProvider);
      ref.invalidate(spaceChildrenProvider);
      ref.invalidate(searchRoomsProvider);
      if (!sheetContext.mounted) return;
      Navigator.of(sheetContext).pop();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(successMessage)));
    } catch (error) {
      if (!suppressionToken.isCurrent) return;
      suppressionNotifier.value = previousSuppression;
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('操作失败: $error')));
    }
  }
}

class _PendingRoomActions extends ConsumerWidget {
  final ChatRoom room;

  const _PendingRoomActions({required this.room});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (room.roomState == 'invited') {
      return Row(
        children: [
          _ActionButton(
            icon: Icons.check_rounded,
            label: '接受',
            onPressed: () => _runAction(
              context,
              ref,
              () => acceptRoomInvite(roomId: room.id),
              successMessage: '已接受邀请',
            ),
          ),
          const SizedBox(width: 8),
          _ActionButton(
            icon: Icons.close_rounded,
            label: '拒绝',
            destructive: true,
            onPressed: () => _runAction(
              context,
              ref,
              () => rejectRoomInvite(roomId: room.id),
              successMessage: '已拒绝邀请',
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        _ActionButton(
          icon: Icons.undo_rounded,
          label: '撤回',
          destructive: true,
          onPressed: () => _runAction(
            context,
            ref,
            () => withdrawRoomKnock(roomId: room.id),
            successMessage: '已撤回请求',
          ),
        ),
      ],
    );
  }

  Future<void> _runAction(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() action, {
    required String successMessage,
  }) async {
    try {
      await action();
      ref.invalidate(chatRoomsProvider);
      ref.invalidate(ungroupedRoomsProvider);
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(successMessage)));
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('操作失败: $error')));
    }
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool destructive;
  final VoidCallback onPressed;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = destructive ? AppColors.error : AppColors.primary;
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.55)),
        visualDensity: VisualDensity.compact,
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    );
  }
}
