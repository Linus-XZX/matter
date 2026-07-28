import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/app_theme.dart';
import 'chat_timestamp.dart';

class PinnedMessagesPage extends ConsumerStatefulWidget {
  final String roomId;

  const PinnedMessagesPage({super.key, required this.roomId});

  @override
  ConsumerState<PinnedMessagesPage> createState() => _PinnedMessagesPageState();
}

class _PinnedMessagesPageState extends ConsumerState<PinnedMessagesPage> {
  late Future<List<rust.ChatMessage>> _messages;

  @override
  void initState() {
    super.initState();
    _messages = rust.getPinnedMessages(roomId: widget.roomId);
  }

  Future<void> _reload() async {
    final messages = rust.getPinnedMessages(roomId: widget.roomId);
    setState(() {
      _messages = messages;
    });
    try {
      await messages;
    } catch (_) {
      // FutureBuilder renders the retry state for this same future.
    }
  }

  @override
  Widget build(BuildContext context) {
    final ignoredUserIdsAsync = ref.watch(ignoredUserIdsProvider);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text(
          '置顶消息',
          style: TextStyle(
            color: AppColors.onBackground,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: FutureBuilder<List<rust.ChatMessage>>(
        future: _messages,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
              child: CircularProgressIndicator(
                color: AppColors.primary,
                strokeWidth: 2,
              ),
            );
          }
          if (snapshot.hasError) {
            return Center(
              child: TextButton.icon(
                onPressed: _reload,
                icon: const Icon(Icons.refresh_rounded),
                label: Text('加载失败: ${snapshot.error}'),
              ),
            );
          }
          final ignoredUserIds = ignoredUserIdsAsync.value ?? const <String>{};
          final messages = (snapshot.data ?? const <rust.ChatMessage>[])
              .where(
                (message) =>
                    message.isMe || !ignoredUserIds.contains(message.senderId),
              )
              .toList();
          if (messages.isEmpty) {
            return RefreshIndicator(
              color: AppColors.primary,
              onRefresh: _reload,
              child: const CustomScrollView(
                physics: AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Text(
                        '暂无置顶消息',
                        style: TextStyle(color: AppColors.onSurfaceVariant),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }
          return RefreshIndicator(
            color: AppColors.primary,
            onRefresh: _reload,
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              itemCount: messages.length,
              separatorBuilder: (_, _) =>
                  const Divider(color: AppColors.surfaceVariant, height: 1),
              itemBuilder: (context, index) {
                final message = messages[index];
                final content = message.content.trim().isEmpty
                    ? (message.filename ?? '媒体消息')
                    : message.content;
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 6,
                  ),
                  leading: const Icon(
                    Icons.push_pin_rounded,
                    color: AppColors.primary,
                  ),
                  title: Text(
                    message.senderName,
                    style: const TextStyle(
                      color: AppColors.onBackground,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    content,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.onSurfaceVariant,
                      height: 1.35,
                    ),
                  ),
                  trailing: Text(
                    formatChatListTime(message.timestamp),
                    style: const TextStyle(
                      color: AppColors.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
