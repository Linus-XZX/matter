import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'action_failure_message.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/app_theme.dart';
import '../../widgets/max_content_width.dart';

class CreateChatPage extends ConsumerStatefulWidget {
  const CreateChatPage({super.key});

  @override
  ConsumerState<CreateChatPage> createState() => _CreateChatPageState();
}

class _CreateChatPageState extends ConsumerState<CreateChatPage> {
  final _searchController = TextEditingController();
  bool _isCreating = false;

  /// Map a failed write's error to the unified timeout wording (same
  /// discipline as the room management page): a queue-wait timeout means
  /// the write may still be landing in its background tail.
  String _actionFailureMessage(Object error) => actionFailureMessage(error);

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _createDm(String userId) async {
    if (_isCreating) return;
    setState(() => _isCreating = true);
    // Account snapshot: a switch while the request is in flight must not
    // redirect the write (and suppresses the feedback below).
    final accountUserId = ref.read(activeUserIdProvider) ?? '';
    try {
      await rust.createDm(accountUserId: accountUserId, userId: userId);
      // The account may have switched while the request was in flight:
      // skip ALL local feedback (same discipline as the other pages).
      // `mounted` first: `ref.read` throws after unmount (Riverpod
      // asserts on disposed widgets).
      if (!mounted) return;
      if (ref.read(activeUserIdProvider) != accountUserId) return;
      // Refresh all room sources like every other write path: the new
      // room must appear in the ungrouped/space lists too (the sync echo
      // would eventually cover it, but not while sync is stalled).
      ref.invalidate(chatRoomsProvider);
      ref.invalidate(ungroupedRoomsProvider);
      ref.invalidate(spacesProvider);
      ref.invalidate(searchRoomsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('私聊已创建'),
            duration: Duration(seconds: 1),
          ),
        );
        // `isCurrent` guard: another modal (e.g. the device-verification
        // dialog) may sit above this page — popping then would dismiss
        // that dialog instead.
        if (ModalRoute.of(context)?.isCurrent == true) {
          Navigator.of(context).pop();
        }
      }
    } catch (e) {
      // 账号可能在请求期间切换：跳过失败反馈（与成功路径一致）。
      // `mounted` first: `ref.read` throws after unmount.
      if (!mounted) return;
      if (ref.read(activeUserIdProvider) != accountUserId) return;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_actionFailureMessage(e)),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isCreating = false);
    }
  }

  Future<void> _createGroup(String name) async {
    if (_isCreating) return;
    setState(() => _isCreating = true);
    // Account snapshot: a switch while the request is in flight must not
    // redirect the write (and suppresses the feedback below).
    final accountUserId = ref.read(activeUserIdProvider) ?? '';
    try {
      await rust.createGroupRoom(
        accountUserId: accountUserId,
        name: name,
        topic: null,
      );
      // The account may have switched while the request was in flight:
      // skip ALL local feedback (same discipline as the other pages).
      // `mounted` first: `ref.read` throws after unmount (Riverpod
      // asserts on disposed widgets).
      if (!mounted) return;
      if (ref.read(activeUserIdProvider) != accountUserId) return;
      // Refresh all room sources like every other write path: the new
      // room must appear in the ungrouped/space lists too (the sync echo
      // would eventually cover it, but not while sync is stalled).
      ref.invalidate(chatRoomsProvider);
      ref.invalidate(ungroupedRoomsProvider);
      ref.invalidate(spacesProvider);
      ref.invalidate(searchRoomsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('群组已创建'),
            duration: Duration(seconds: 1),
          ),
        );
        // `isCurrent` guard: another modal may sit above this page.
        if (ModalRoute.of(context)?.isCurrent == true) {
          Navigator.of(context).pop();
        }
      }
    } catch (e) {
      // 账号可能在请求期间切换：跳过失败反馈（与成功路径一致）。
      // `mounted` first: `ref.read` throws after unmount.
      if (!mounted) return;
      if (ref.read(activeUserIdProvider) != accountUserId) return;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_actionFailureMessage(e)),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isCreating = false);
    }
  }

  void _showJoinRoomDialog() {
    // Account snapshot captured when the dialog OPENS: a switch while the
    // dialog is up must not redirect the write to the new account.
    final dialogAccountUserId = ref.read(activeUserIdProvider) ?? '';
    final roomIdController = TextEditingController();
    var joining = false;
    String? joinError;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.surface),
          ),
          title: const Text(
            '加入房间',
            style: TextStyle(color: AppColors.onBackground),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: roomIdController,
                style: const TextStyle(color: AppColors.onBackground),
                decoration: const InputDecoration(
                  hintText: '!room_id:matrix.akass.cn',
                  hintStyle: TextStyle(color: AppColors.onSurfaceVariant),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: AppColors.surfaceVariant),
                  ),
                ),
              ),
              if (joinError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    joinError!,
                    style: const TextStyle(
                      color: AppColors.error,
                      fontSize: 13,
                    ),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: joining ? null : () => Navigator.of(ctx).pop(),
              child: const Text(
                '取消',
                style: TextStyle(color: AppColors.onSurfaceVariant),
              ),
            ),
            TextButton(
              onPressed: joining
                  ? null
                  : () async {
                      // Entry guard (not only the disabled button): the
                      // rebuild lags a frame, so a second tap on the old
                      // widget could otherwise issue a duplicate join.
                      if (joining) return;
                      final value = roomIdController.text.trim();
                      if (value.isEmpty) {
                        // Feedback instead of a silent no-op (same
                        // discipline as the create-group dialog).
                        setDialogState(() => joinError = '请输入房间 ID 或别名');
                        return;
                      }
                      setDialogState(() {
                        joining = true;
                        joinError = null;
                      });
                      try {
                        await rust.joinRoom(
                          // Account snapshot captured when the dialog
                          // OPENED (see above), not read at tap time.
                          accountUserId: dialogAccountUserId,
                          identifier: value,
                        );
                        // The account may have switched while the request
                        // was in flight: skip ALL local feedback (same
                        // discipline as the other pages) and close the
                        // dialog — it would otherwise stay stuck in its
                        // in-flight state. `mounted` first: `ref.read`
                        // throws after unmount.
                        if (!mounted) return;
                        if (ref.read(activeUserIdProvider) !=
                            dialogAccountUserId) {
                          if (ctx.mounted &&
                              ModalRoute.of(ctx)?.isCurrent == true) {
                            Navigator.of(ctx).pop();
                          }
                          return;
                        }
                        ref.invalidate(chatRoomsProvider);
                        ref.invalidate(ungroupedRoomsProvider);
                        ref.invalidate(spacesProvider);
                        ref.invalidate(searchRoomsProvider);
                        if (!mounted) return;
                        // `isCurrent` guard: the dialog may already be in
                        // its exit animation — popping then would pop the
                        // page below it.
                        if (ctx.mounted &&
                            ModalRoute.of(ctx)?.isCurrent == true) {
                          Navigator.of(ctx).pop();
                        }
                        // The dialog may have been dismissed while the
                        // request was in flight: still report success.
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('已加入房间'),
                            duration: Duration(seconds: 1),
                          ),
                        );
                      } catch (e) {
                        if (!mounted) return;
                        // 账号可能在请求期间切换：跳过失败反馈（与成功路径一致）。
                        if (ref.read(activeUserIdProvider) !=
                            dialogAccountUserId) {
                          if (ctx.mounted &&
                              ModalRoute.of(ctx)?.isCurrent == true) {
                            Navigator.of(ctx).pop();
                          }
                          return;
                        }
                        if (ctx.mounted) {
                          setDialogState(() {
                            joining = false;
                            // Render the failure inside the dialog: a
                            // page-level snackbar would sit beneath the
                            // modal barrier while the dialog stays open
                            // for retry.
                            joinError = _actionFailureMessage(e);
                          });
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(_actionFailureMessage(e)),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        }
                      }
                    },
              child: joining
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text(
                      '加入',
                      style: TextStyle(color: AppColors.primary),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_rounded,
            color: AppColors.onBackground,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          '新建聊天',
          style: TextStyle(
            color: AppColors.onBackground,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: MaxContentWidth(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              // Search / user ID input
              Container(
                decoration: BoxDecoration(
                  color: AppColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(AppRadii.surface),
                ),
                child: TextField(
                  controller: _searchController,
                  style: const TextStyle(
                    color: AppColors.onBackground,
                    fontSize: 15,
                  ),
                  decoration: const InputDecoration(
                    hintText: '输入 @用户 ID 发起私聊',
                    hintStyle: TextStyle(
                      color: AppColors.onSurfaceVariant,
                      fontSize: 15,
                    ),
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      color: AppColors.onSurfaceVariant,
                      size: 20,
                    ),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: 14),
                    isDense: true,
                  ),
                  textInputAction: TextInputAction.go,
                  onSubmitted: (value) {
                    final trimmed = value.trim();
                    if (trimmed.isNotEmpty) _createDm(trimmed);
                  },
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: () {
                    final trimmed = _searchController.text.trim();
                    if (trimmed.isNotEmpty) _createDm(trimmed);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadii.surface),
                    ),
                  ),
                  child: _isCreating
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Text(
                          '发起私聊',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 32),
              // Action cards
              _ActionCard(
                icon: Icons.group_add_rounded,
                iconColor: AppColors.primary,
                title: '创建群组',
                subtitle: '创建一个新的群聊房间',
                onTap: () {
                  final nameController = TextEditingController();
                  String? groupNameError;
                  showDialog(
                    context: context,
                    builder: (ctx) => StatefulBuilder(
                      builder: (ctx, setDialogState) => AlertDialog(
                        backgroundColor: AppColors.surface,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadii.surface),
                        ),
                        title: const Text(
                          '创建群组',
                          style: TextStyle(color: AppColors.onBackground),
                        ),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextField(
                              controller: nameController,
                              style: const TextStyle(
                                color: AppColors.onBackground,
                              ),
                              decoration: const InputDecoration(
                                hintText: '群组名称',
                                hintStyle: TextStyle(
                                  color: AppColors.onSurfaceVariant,
                                ),
                                enabledBorder: UnderlineInputBorder(
                                  borderSide: BorderSide(
                                    color: AppColors.surfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                            if (groupNameError != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Text(
                                  groupNameError!,
                                  style: const TextStyle(
                                    color: AppColors.error,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            child: const Text(
                              '取消',
                              style: TextStyle(
                                color: AppColors.onSurfaceVariant,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: () {
                              final name = nameController.text.trim();
                              if (name.isEmpty) {
                                // Feedback instead of silently closing the
                                // dialog (same discipline as the space
                                // dialogs).
                                setDialogState(
                                  () => groupNameError = '群组名称不能为空',
                                );
                                return;
                              }
                              Navigator.of(ctx).pop();
                              _createGroup(name);
                            },
                            child: const Text(
                              '创建',
                              style: TextStyle(color: AppColors.primary),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 8),
              _ActionCard(
                icon: Icons.meeting_room_rounded,
                iconColor: AppColors.warning,
                title: '加入房间',
                subtitle: '通过房间 ID 加入已有房间',
                onTap: _showJoinRoomDialog,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ActionCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.surface),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadii.surface),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadii.content),
                ),
                child: Icon(icon, color: iconColor, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: AppColors.onBackground,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: AppColors.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: AppColors.onSurfaceVariant,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
