import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/app_theme.dart';
import '../../widgets/app_avatar.dart';
import 'chat_detail_page.dart';
import 'chat_list_item.dart';
import 'chat_timestamp.dart';

const _searchPageSize = 30;
const _maxSearchResults = 500;

List<rust.ChatRoom> filterRoomsForSearch(
  List<rust.ChatRoom> rooms,
  String query,
) {
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) return const [];
  return rooms.where((room) {
    if (room.roomState != 'joined') return false;
    return room.name.toLowerCase().contains(normalized) ||
        room.id.toLowerCase().contains(normalized);
  }).toList();
}

class ChatSearchPage extends ConsumerStatefulWidget {
  final String? roomId;

  const ChatSearchPage({super.key, this.roomId});

  @override
  ConsumerState<ChatSearchPage> createState() => _ChatSearchPageState();
}

class _ChatSearchPageState extends ConsumerState<ChatSearchPage> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  Timer? _debounce;
  String _query = '';
  String _activeQuery = '';
  int _resultLimit = _searchPageSize;

  bool get _isRoomSearch => widget.roomId != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    setState(() => _query = value);
    _debounce = Timer(const Duration(milliseconds: 280), () {
      if (!mounted) return;
      setState(() {
        _activeQuery = value.trim();
        _resultLimit = _searchPageSize;
      });
    });
  }

  void _clearQuery() {
    _debounce?.cancel();
    _controller.clear();
    setState(() {
      _query = '';
      _activeQuery = '';
      _resultLimit = _searchPageSize;
    });
    _focusNode.requestFocus();
  }

  void _loadMore() {
    setState(() {
      final nextLimit = _resultLimit + _searchPageSize;
      _resultLimit = nextLimit > _maxSearchResults
          ? _maxSearchResults
          : nextLimit;
    });
  }

  @override
  Widget build(BuildContext context) {
    final appBar = AppBar(
      backgroundColor: AppColors.background,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleSpacing: 0,
      title: Container(
        height: 40,
        margin: const EdgeInsets.only(right: 12),
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(AppRadii.surface),
        ),
        child: TextField(
          key: const ValueKey('chat-search-field'),
          controller: _controller,
          focusNode: _focusNode,
          onChanged: _onQueryChanged,
          textInputAction: TextInputAction.search,
          style: const TextStyle(color: AppColors.onBackground, fontSize: 15),
          decoration: InputDecoration(
            hintText: _isRoomSearch ? '搜索此聊天的消息' : '搜索消息或聊天',
            hintStyle: const TextStyle(
              color: AppColors.onSurfaceVariant,
              fontSize: 15,
            ),
            prefixIcon: const Icon(
              Icons.search_rounded,
              size: 20,
              color: AppColors.onSurfaceVariant,
            ),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    tooltip: '清除',
                    onPressed: _clearQuery,
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
          ),
        ),
      ),
      bottom: _isRoomSearch
          ? null
          : const TabBar(
              tabs: [
                Tab(text: '消息'),
                Tab(text: '聊天'),
              ],
              labelColor: AppColors.primary,
              unselectedLabelColor: AppColors.onSurfaceVariant,
              indicatorColor: AppColors.primary,
              dividerColor: AppColors.surfaceVariant,
            ),
    );

    final body = _isRoomSearch
        ? _MessageSearchResults(
            query: _activeQuery,
            roomId: widget.roomId,
            limit: _resultLimit,
            onLoadMore: _loadMore,
          )
        : TabBarView(
            children: [
              _MessageSearchResults(
                query: _activeQuery,
                limit: _resultLimit,
                onLoadMore: _loadMore,
              ),
              _RoomSearchResults(query: _query),
            ],
          );

    final scaffold = Scaffold(
      backgroundColor: AppColors.background,
      appBar: appBar,
      body: body,
    );
    if (_isRoomSearch) return scaffold;
    return DefaultTabController(length: 2, child: scaffold);
  }
}

class _MessageSearchResults extends ConsumerWidget {
  final String query;
  final String? roomId;
  final int limit;
  final VoidCallback onLoadMore;

  const _MessageSearchResults({
    required this.query,
    this.roomId,
    required this.limit,
    required this.onLoadMore,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (query.isEmpty) return const SizedBox.shrink();
    final request = MessageSearchRequest(
      query: query,
      roomId: roomId,
      limit: limit,
    );
    final search = ref.watch(messageSearchProvider(request));
    return search.when(
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (error, _) => _SearchStatus(
        icon: Icons.error_outline_rounded,
        text: '搜索失败: $error',
        action: IconButton(
          tooltip: '重试',
          onPressed: () => ref.invalidate(messageSearchProvider(request)),
          icon: const Icon(Icons.refresh_rounded),
        ),
      ),
      data: (page) {
        if (page.results.isEmpty) {
          return const _SearchStatus(
            icon: Icons.search_off_rounded,
            text: '没有找到匹配的消息',
          );
        }
        final canLoadMore = page.hasMore && limit < _maxSearchResults;
        return ListView.separated(
          key: const PageStorageKey('message-search-results'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          itemCount: page.results.length + (canLoadMore ? 1 : 0),
          separatorBuilder: (_, _) => const Divider(
            height: 0.5,
            thickness: 0.5,
            color: AppColors.surfaceVariant,
          ),
          itemBuilder: (context, index) {
            if (index == page.results.length) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: TextButton.icon(
                    onPressed: onLoadMore,
                    icon: const Icon(Icons.expand_more_rounded, size: 18),
                    label: const Text('加载更多'),
                  ),
                ),
              );
            }
            return _MessageSearchTile(
              result: page.results[index],
              query: query,
              roomScoped: roomId != null,
            );
          },
        );
      },
    );
  }
}

class _MessageSearchTile extends ConsumerWidget {
  final rust.MessageSearchResult result;
  final String query;
  final bool roomScoped;

  const _MessageSearchTile({
    required this.result,
    required this.query,
    required this.roomScoped,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return InkWell(
      key: ValueKey('message-search-result-${result.eventId}'),
      onTap: () => _openResult(context, ref),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppAvatar(
              fallback: roomScoped ? result.senderName : result.roomName,
              size: 40,
              radius: AppRadii.content,
              url: roomScoped ? null : result.roomAvatarUrl,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          roomScoped ? result.senderName : result.roomName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.onBackground,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatChatListTime(result.timestamp),
                        style: const TextStyle(
                          color: AppColors.onSurfaceVariant,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                  if (!roomScoped) ...[
                    const SizedBox(height: 2),
                    Text(
                      result.isEdited
                          ? '${result.senderName} · 已编辑'
                          : result.senderName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  const SizedBox(height: 5),
                  _HighlightedMessageText(text: result.body, query: query),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openResult(BuildContext context, WidgetRef ref) async {
    if (roomScoped) {
      Navigator.of(context).pop(result.eventId);
      return;
    }

    rust.ChatRoom? room;
    final rooms = ref.read(chatRoomsProvider).asData?.value;
    if (rooms != null) {
      for (final candidate in rooms) {
        if (candidate.id == result.roomId) {
          room = candidate;
          break;
        }
      }
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatDetailPage(
          roomId: result.roomId,
          roomName: result.roomName,
          avatarUrl: result.roomAvatarUrl,
          nameEventId: room?.nameEventId,
          avatarEventId: room?.avatarEventId,
          isDm: result.isDm,
          initialMessageId: result.eventId,
        ),
      ),
    );
  }
}

class _HighlightedMessageText extends StatelessWidget {
  final String text;
  final String query;

  const _HighlightedMessageText({required this.text, required this.query});

  @override
  Widget build(BuildContext context) {
    final normalizedText = text.toLowerCase();
    final trimmedQuery = query.trim();
    final normalizedQuery = trimmedQuery.toLowerCase();
    final preservesOffsets =
        normalizedText.length == text.length &&
        normalizedQuery.length == trimmedQuery.length;
    final index = normalizedQuery.isEmpty || !preservesOffsets
        ? -1
        : normalizedText.indexOf(normalizedQuery);
    const normalStyle = TextStyle(
      color: AppColors.onBackground,
      fontSize: 14,
      height: 1.35,
    );
    if (index < 0) {
      return Text(
        text,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: normalStyle,
      );
    }
    final end = index + normalizedQuery.length;
    return Text.rich(
      TextSpan(
        style: normalStyle,
        children: [
          if (index > 0) TextSpan(text: text.substring(0, index)),
          TextSpan(
            text: text.substring(index, end),
            style: const TextStyle(
              color: AppColors.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (end < text.length) TextSpan(text: text.substring(end)),
        ],
      ),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _RoomSearchResults extends ConsumerWidget {
  final String query;

  const _RoomSearchResults({required this.query});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (query.trim().isEmpty) return const SizedBox.shrink();
    return ref
        .watch(chatRoomsProvider)
        .when(
          loading: () =>
              const Center(child: CircularProgressIndicator(strokeWidth: 2)),
          error: (error, _) => _SearchStatus(
            icon: Icons.error_outline_rounded,
            text: '加载聊天失败: $error',
          ),
          data: (rooms) {
            final results = filterRoomsForSearch(rooms, query);
            if (results.isEmpty) {
              return const _SearchStatus(
                icon: Icons.search_off_rounded,
                text: '没有找到匹配的聊天',
              );
            }
            return ListView.separated(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              itemCount: results.length,
              separatorBuilder: (_, _) => const Divider(
                height: 0.5,
                thickness: 0.5,
                color: AppColors.surfaceVariant,
              ),
              itemBuilder: (_, index) => ChatListItem(room: results[index]),
            );
          },
        );
  }
}

class _SearchStatus extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;

  const _SearchStatus({required this.icon, required this.text, this.action});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: AppColors.onSurfaceVariant, size: 28),
            const SizedBox(height: 10),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.onSurfaceVariant),
            ),
            if (action != null) ...[const SizedBox(height: 8), action!],
          ],
        ),
      ),
    );
  }
}
