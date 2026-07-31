import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
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
  List<rust.ChatMessage>? _messages;
  Object? _loadError;
  bool _loading = true;
  bool _reloadTrailing = false;
  Completer<void>? _reloadCompletion;
  late final StreamSubscription<rust.SyncEvent> _syncSubscription;
  late final Future<String?> _roomSubscription;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
    _syncSubscription = rust.watchSyncEvents().listen((event) {
      final shouldReload = switch (event) {
        rust.SyncEvent_PinnedMessagesChanged(:final roomId) =>
          roomId == widget.roomId,
        rust.SyncEvent_FullRefreshRequired() => true,
        _ => false,
      };
      if (shouldReload && mounted) {
        unawaited(_reload());
      }
    });
    // Keep room-level state in Sliding Sync while this page covers the chat.
    _roomSubscription = rust
        .subscribeRoomForReceipts(
          roomId: widget.roomId,
          accountUserId: ref.read(activeUserIdProvider),
        )
        .then<String?>((subscriptionId) => subscriptionId)
        .catchError((error) {
          debugPrint('subscribe pinned room updates failed: $error');
          return null;
        });
  }

  @override
  void dispose() {
    _syncSubscription.cancel();
    unawaited(_unsubscribeAfterSubscribe());
    super.dispose();
  }

  Future<void> _unsubscribeAfterSubscribe() async {
    final subscriptionId = await _roomSubscription;
    if (subscriptionId == null) return;
    try {
      await rust.unsubscribeRoomForReceipts(
        roomId: widget.roomId,
        subscriptionId: subscriptionId,
      );
    } catch (error) {
      debugPrint('unsubscribe pinned room updates failed: $error');
    }
  }

  Future<void> _reload({bool showLoading = false}) {
    final active = _reloadCompletion;
    if (active != null) {
      _reloadTrailing = true;
      return active.future;
    }
    if (showLoading && _messages == null) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    final completion = Completer<void>();
    _reloadCompletion = completion;
    unawaited(_runReloads(completion));
    return completion.future;
  }

  Future<void> _runReloads(Completer<void> completion) async {
    try {
      do {
        _reloadTrailing = false;
        try {
          final messages = await rust.getPinnedMessages(roomId: widget.roomId);
          if (!mounted) return;
          setState(() {
            _messages = messages;
            _loadError = null;
            _loading = false;
          });
        } catch (error) {
          if (!mounted) return;
          setState(() {
            _loadError = error;
            _loading = false;
          });
        }
      } while (_reloadTrailing && mounted);
    } finally {
      _reloadCompletion = null;
      completion.complete();
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
      body: _buildBody(ignoredUserIdsAsync),
    );
  }

  Widget _buildBody(AsyncValue<Set<String>> ignoredUserIdsAsync) {
    if (_loading && _messages == null) {
      return const Center(
        child: CircularProgressIndicator(
          color: AppColors.primary,
          strokeWidth: 2,
        ),
      );
    }
    if (_messages == null) {
      return Center(
        child: TextButton.icon(
          onPressed: () {
            unawaited(_reload(showLoading: true));
          },
          icon: const Icon(Icons.refresh_rounded),
          label: Text('加载失败: $_loadError'),
        ),
      );
    }
    final ignoredUserIds = ignoredUserIdsAsync.value;
    // An unknown ignore list must not degrade into "nobody is ignored".
    if (ignoredUserIds == null) {
      if (ignoredUserIdsAsync.hasError) {
        return Center(
          child: TextButton.icon(
            onPressed: () => ref.invalidate(ignoredUserIdsProvider),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('无法加载忽略列表，消息已隐藏'),
          ),
        );
      }
      return const Center(
        child: CircularProgressIndicator(
          color: AppColors.primary,
          strokeWidth: 2,
        ),
      );
    }
    final messages = _messages!
        .where(
          (message) =>
              message.isMe || !ignoredUserIds.contains(message.senderId),
        )
        .toList();
    if (messages.isEmpty) {
      return RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _reload,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: _loadError == null
                    ? const Text(
                        '暂无置顶消息',
                        style: TextStyle(color: AppColors.onSurfaceVariant),
                      )
                    : _refreshErrorTile(),
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
        itemCount: messages.length + (_loadError == null ? 0 : 1),
        separatorBuilder: (_, _) =>
            const Divider(color: AppColors.surfaceVariant, height: 1),
        itemBuilder: (context, index) {
          if (_loadError != null && index == 0) return _refreshErrorTile();
          final message = messages[index - (_loadError == null ? 0 : 1)];
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
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  formatChatListTime(message.timestamp),
                  style: const TextStyle(
                    color: AppColors.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: '取消置顶',
                  icon: const Icon(
                    Icons.push_pin_outlined,
                    color: AppColors.onSurfaceVariant,
                    size: 18,
                  ),
                  onPressed: () => unawaited(_unpin(message)),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _unpin(rust.ChatMessage message) async {
    try {
      await rust.togglePinnedMessage(
        roomId: widget.roomId,
        eventId: message.id,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已取消置顶'), duration: Duration(seconds: 1)),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('取消置顶失败: $error'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Widget _refreshErrorTile() {
    return ListTile(
      leading: const Icon(Icons.sync_problem_rounded, color: AppColors.error),
      title: const Text(
        '刷新失败，当前显示上次结果',
        style: TextStyle(color: AppColors.onBackground),
      ),
      subtitle: Text(
        '$_loadError',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: AppColors.onSurfaceVariant),
      ),
      trailing: IconButton(
        tooltip: '重试刷新',
        onPressed: () => unawaited(_reload()),
        icon: const Icon(Icons.refresh_rounded),
      ),
    );
  }
}
