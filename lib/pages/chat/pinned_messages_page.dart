import 'dart:async';

import 'package:clock/clock.dart';
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
  /// Message ids whose unpin request is in flight, mapped to the moment the
  /// lock was taken. The server toggle is a read-modify-write: without this
  /// guard a double-tap on the unpin button would first remove the pin and
  /// then re-add it (the second toggle runs against the already-unpinned
  /// server state). Locks expire after [_unpinLockTimeout] so a message that
  /// gets re-pinned on another device (or a row that never leaves a stale
  /// list) cannot disable its button forever.
  final Map<String, DateTime> _pendingUnpinIds = {};
  static const Duration _unpinLockTimeout = Duration(seconds: 30);
  Timer? _unpinLockExpiryTimer;
  /// Toggles still awaiting their server response, independent of the lock:
  /// a lock may expire while its toggle is still in flight (very slow
  /// network), and the button must stay disabled either way.
  final Set<String> _inflightUnpinIds = {};

  bool _unpinLocked(String messageId) {
    final lockedAt = _pendingUnpinIds[messageId];
    if (lockedAt == null) return false;
    if (clock.now().difference(lockedAt) >= _unpinLockTimeout) {
      _pendingUnpinIds.remove(messageId);
      return false;
    }
    return true;
  }

  void _scheduleUnpinLockExpiry() {
    _unpinLockExpiryTimer?.cancel();
    if (_pendingUnpinIds.isEmpty) return;
    final now = clock.now();
    final nextExpiry = _pendingUnpinIds.values
        .map((lockedAt) => lockedAt.add(_unpinLockTimeout))
        .reduce((earlier, later) => earlier.isBefore(later) ? earlier : later);
    final delay = nextExpiry.difference(now);
    _unpinLockExpiryTimer = Timer(
      delay.isNegative ? Duration.zero : delay,
      () {
        if (!mounted) return;
        setState(() {
          _pendingUnpinIds.removeWhere(
            (_, lockedAt) =>
                !lockedAt.add(_unpinLockTimeout).isAfter(nextExpiry),
          );
        });
        _scheduleUnpinLockExpiry();
      },
    );
  }
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
    _unpinLockExpiryTimer?.cancel();
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
            // Release only the locks whose message left the list. A reload
            // can serve a stale snapshot (the offline store fallback, or a
            // concurrent toggle still queued on the server), so a row that
            // is still present keeps its lock until a later reload removes
            // it — otherwise the unlocked row invites a re-pinning tap.
            // Locked ids whose row left the list are settled either way.
            _pendingUnpinIds.removeWhere(
              (id, _) => !messages.any((message) => message.id == id),
            );
            _scheduleUnpinLockExpiry();
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
                  onPressed: _unpinLocked(message.id) ||
                          _inflightUnpinIds.contains(message.id)
                      ? null
                      : () => unawaited(_unpin(message)),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _unpin(rust.ChatMessage message) async {
    if (_unpinLocked(message.id) || _inflightUnpinIds.contains(message.id)) {
      return;
    }
    if (_messages == null) return;
    final originalIndex = _messages!.indexWhere((m) => m.id == message.id);
    setState(() {
      _pendingUnpinIds[message.id] = clock.now();
      _inflightUnpinIds.add(message.id);
      _scheduleUnpinLockExpiry();
      // Drop the row optimistically: the removal was accepted by the server
      // and keeping the row visible would invite a second tap that re-pins
      // the message while the confirming reload is still in flight.
      _messages = List.of(_messages!)..removeWhere((m) => m.id == message.id);
    });
    try {
      // The toggle returns the message's pinned state *after* the server
      // write, which is authoritative: a stale list (refreshed elsewhere)
      // that already dropped the pin flips the message back to pinned, and
      // reporting that beats claiming "已取消置顶".
      final pinned = await rust.togglePinnedMessage(
        roomId: widget.roomId,
        eventId: message.id,
      );
      if (!mounted) return;
      setState(() {
        _inflightUnpinIds.remove(message.id);
        if (pinned) {
          // The server re-pinned the message (the local list was stale):
          // release the lock so the reload can restore the row with an
          // actionable button.
          _pendingUnpinIds.remove(message.id);
        }
        _scheduleUnpinLockExpiry();
      });
      // Otherwise keep the id in _pendingUnpinIds: the button stays locked
      // until a reload confirms the message left the list (see _runReloads),
      // or the lock times out — a stale reload snapshot must not unlock it
      // early, and a cross-device re-pin must not lock it forever.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(pinned ? '消息已置顶' : '已取消置顶'),
          duration: const Duration(seconds: 1),
        ),
      );
      // Refresh towards the server state: after a removal the row stays
      // gone; after a re-pin (stale local list) it must come back.
      unawaited(_reload());
    } catch (error) {
      if (!mounted) return;
      setState(() {
        // The server still has the pin (the request failed): restore the
        // row at its previous position (the list is ordered by the server's
        // pinned state, so appending at the top would misrepresent it), and
        // release the lock so the user can retry.
        _pendingUnpinIds.remove(message.id);
        _inflightUnpinIds.remove(message.id);
        _scheduleUnpinLockExpiry();
        if (_messages != null &&
            !_messages!.any((entry) => entry.id == message.id)) {
          final insertAt = originalIndex.clamp(0, _messages!.length);
          _messages = List.of(_messages!)..insert(insertAt, message);
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('取消置顶失败: $error'),
          duration: const Duration(seconds: 2),
        ),
      );
      // Reconcile against the server: the write may have partially landed
      // (request reached the server, response lost), so re-read the list
      // instead of trusting the local restore.
      unawaited(_reload());
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
