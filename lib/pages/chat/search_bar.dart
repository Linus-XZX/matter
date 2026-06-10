import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/chat_provider.dart';
import '../../theme/app_theme.dart';
import 'chat_list_item.dart';

class ChatSearchBar extends ConsumerStatefulWidget {
  const ChatSearchBar({super.key});

  @override
  ConsumerState<ChatSearchBar> createState() => _ChatSearchBarState();
}

class _ChatSearchBarState extends ConsumerState<ChatSearchBar> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _isSearching = false;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _startSearch() {
    setState(() => _isSearching = true);
    _focusNode.requestFocus();
  }

  void _stopSearch() {
    setState(() {
      _isSearching = false;
      _controller.clear();
    });
    _focusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(AppRadii.surface),
        ),
        child: Row(
          children: [
            const SizedBox(width: 12),
            const Icon(
              Icons.search_rounded,
              color: AppColors.onSurfaceVariant,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                style: const TextStyle(
                  color: AppColors.onBackground,
                  fontSize: 15,
                ),
                decoration: InputDecoration(
                  hintText: '搜索聊天',
                  hintStyle: const TextStyle(
                    color: AppColors.onSurfaceVariant,
                    fontSize: 15,
                  ),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  isDense: true,
                ),
                onTap: _startSearch,
                onChanged: (value) {
                  if (value.trim().isNotEmpty) {
                    ref.read(searchRoomsProvider(value.trim()));
                  }
                },
              ),
            ),
            if (_isSearching)
              GestureDetector(
                onTap: _stopSearch,
                child: const Padding(
                  padding: EdgeInsets.only(right: 12),
                  child: Icon(
                    Icons.close_rounded,
                    color: AppColors.onSurfaceVariant,
                    size: 18,
                  ),
                ),
              )
            else
              const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}

/// Overlay that shows search results
class ChatSearchResults extends ConsumerWidget {
  final String query;

  const ChatSearchResults({super.key, required this.query});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (query.trim().isEmpty) return const SizedBox.shrink();

    final resultsAsync = ref.watch(searchRoomsProvider(query));

    return resultsAsync.when(
      data: (rooms) {
        if (rooms.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(32),
            child: Center(
              child: Text(
                '没有找到匹配的聊天',
                style: TextStyle(color: AppColors.onSurfaceVariant),
              ),
            ),
          );
        }
        return Column(
          children: rooms.map((room) => ChatListItem(room: room)).toList(),
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(
          child: CircularProgressIndicator(
            color: AppColors.primary,
            strokeWidth: 2,
          ),
        ),
      ),
      error: (err, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          '搜索失败: $err',
          style: const TextStyle(color: AppColors.onSurfaceVariant),
        ),
      ),
    );
  }
}
