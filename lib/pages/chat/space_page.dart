import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'action_failure_message.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/connection_provider.dart';
import '../../src/rust/api/matrix.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/cascade_title.dart';
import 'chat_list_item.dart';
import 'space_detail_page.dart';

class SpacePage extends ConsumerWidget {
  const SpacePage({super.key});

  /// Map a failed write's error to the unified timeout wording (same
  /// discipline as the room management page): a queue-wait timeout means
  /// the write may still be landing in its background tail.
  static String _actionFailureMessage(Object error) =>
      actionFailureMessage(error);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spacesAsync = ref.watch(spacesProvider);
    final ungroupedAsync = ref.watch(ungroupedRoomsProvider);
    final connectionLabel = ref.watch(connectionLabelProvider);
    final titleText = connectionLabel.isNotEmpty ? connectionLabel : '空间';

    return Scaffold(
      body: Stack(
        children: [
          CustomScrollView(
            slivers: [
              SliverAppBar(
                floating: true,
                pinned: true,
                expandedHeight: 56,
                collapsedHeight: 56,
                toolbarHeight: 56,
                flexibleSpace: FlexibleSpaceBar(
                  titlePadding: const EdgeInsets.only(left: 16, bottom: 12),
                  title: CascadeTitle(
                    text: titleText,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: AppColors.onBackground,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
                backgroundColor: AppColors.background.withValues(alpha: 0.85),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 12)),
              spacesAsync.when(
                data: (spaces) {
                  if (spaces.isEmpty) {
                    return const SliverToBoxAdapter(
                      child: _SectionCard(
                        title: '空间',
                        subtitle: '暂无已加入空间',
                        child: _HintText('当前账号还没有可浏览的空间。'),
                      ),
                    );
                  }

                  return SliverToBoxAdapter(
                    child: _SectionCard(
                      title: '空间',
                      subtitle: '用于组织房间和成员，不直接作为聊天入口',
                      child: Column(
                        children: [
                          for (final space in spaces)
                            _SpaceRoomTile(
                              space: space,
                              key: ValueKey(space.id),
                            ),
                        ],
                      ),
                    ),
                  );
                },
                loading: () => const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(
                      child: CircularProgressIndicator(
                        color: AppColors.primary,
                        strokeWidth: 2,
                      ),
                    ),
                  ),
                ),
                error: (err, _) => SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      '加载空间失败: $err',
                      style: const TextStyle(color: AppColors.onSurfaceVariant),
                    ),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 12)),
              ungroupedAsync.when(
                data: (rooms) {
                  return SliverToBoxAdapter(
                    child: _SectionCard(
                      title: '未归属群组',
                      subtitle: '这些房间当前不属于任何已加入空间',
                      child: rooms.isEmpty
                          ? const _HintText('暂无普通房间')
                          : Column(
                              children: [
                                for (final room in rooms)
                                  ChatListItem(
                                    room: room,
                                    dense: true,
                                    showRoomTypeIcon: true,
                                  ),
                              ],
                            ),
                    ),
                  );
                },
                loading: () =>
                    const SliverToBoxAdapter(child: SizedBox.shrink()),
                error: (_, _) =>
                    const SliverToBoxAdapter(child: SizedBox.shrink()),
              ),
              const SliverPadding(padding: EdgeInsets.only(bottom: 96)),
            ],
          ),
          Positioned(
            right: 16,
            bottom: 96,
            child: FloatingActionButton(
              onPressed: () => _showSpaceActions(context),
              backgroundColor: AppColors.secondary,
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(
                Icons.add_rounded,
                color: Colors.white,
                size: 24,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showSpaceActions(BuildContext context) {
    // The sheet builder below shadows [context] with the sheet's own
    // context, which is unmounted once the sheet is dismissed. The
    // create/join dialogs opened from here keep the PAGE context for
    // their async completion paths (their writes can outlive the sheet's
    // exit animation — feedback must not vanish with it).
    final pageContext = context;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        margin: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadii.surface),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ActionTile(
                icon: Icons.create_new_folder_rounded,
                title: '创建空间',
                subtitle: '创建一个新的组织空间',
                onTap: () {
                  Navigator.of(context).pop();
                  _showCreateSpaceDialog(pageContext);
                },
              ),
              _ActionTile(
                icon: Icons.travel_explore_rounded,
                title: '加入空间',
                subtitle: '通过空间 ID 或链接加入',
                onTap: () {
                  Navigator.of(context).pop();
                  _showJoinSpaceDialog(pageContext);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showCreateSpaceDialog(BuildContext context) {
    // Account snapshot captured when the dialog OPENS: a switch while the
    // dialog is up must not redirect the write to the new account (same
    // discipline as every other P0 write path).
    final container = ProviderScope.containerOf(context, listen: false);
    final dialogAccountUserId = container.read(activeUserIdProvider) ?? '';
    var spaceName = '';
    var spaceTopic = '';
    var creating = false;
    String? createError;
    // (The page-scoped container is captured at the top of this method.)
    showDialog(
      context: context,
      builder: (ctx) => Consumer(
        builder: (_, ref, _) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            backgroundColor: AppColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.surface),
            ),
            title: const Text(
              '创建空间',
              style: TextStyle(color: AppColors.onBackground),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  onChanged: (value) => spaceName = value,
                  style: const TextStyle(color: AppColors.onBackground),
                  decoration: const InputDecoration(
                    hintText: '空间名称',
                    hintStyle: TextStyle(color: AppColors.onSurfaceVariant),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  onChanged: (value) => spaceTopic = value,
                  style: const TextStyle(color: AppColors.onBackground),
                  decoration: const InputDecoration(
                    hintText: '空间说明（可选）',
                    hintStyle: TextStyle(color: AppColors.onSurfaceVariant),
                  ),
                ),
                if (createError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      createError!,
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
                onPressed: creating ? null : () => Navigator.of(ctx).pop(),
                child: const Text(
                  '取消',
                  style: TextStyle(color: AppColors.onSurfaceVariant),
                ),
              ),
              TextButton(
                onPressed: creating
                    ? null
                    : () async {
                        // Entry guard (not only the disabled button): the
                        // rebuild lags a frame, so a second tap on the old
                        // widget could otherwise create two spaces.
                        if (creating) return;
                        final name = spaceName.trim();
                        final topic = spaceTopic.trim();
                        if (name.isEmpty) {
                          // Feedback instead of a silent no-op (same as
                          // the room management save path).
                          setDialogState(() => createError = '空间名称不能为空');
                          return;
                        }
                        setDialogState(() {
                          creating = true;
                          createError = null;
                        });
                        try {
                          await createSpace(
                            // Account snapshot captured when the dialog
                            // OPENED (see below), not read at tap time.
                            accountUserId: dialogAccountUserId,
                            name: name,
                            topic: topic.isEmpty ? null : topic,
                          );
                          // The account may have switched while the request
                          // was in flight: skip ALL local feedback (same
                          // discipline as the other pages) and close the
                          // dialog — it would otherwise stay stuck in its
                          // in-flight state above the new account's page.
                          if (container.read(activeUserIdProvider) !=
                              dialogAccountUserId) {
                            if (ctx.mounted &&
                                ModalRoute.of(ctx)?.isCurrent == true) {
                              Navigator.of(ctx).pop();
                            }
                            return;
                          }
                          container.invalidate(spacesProvider);
                          container.invalidate(chatRoomsProvider);
                          if (!context.mounted) return;
                          // `isCurrent` guards against popping the page when
                          // the dialog was dismissed during its exit
                          // transition (mounted stays true through it).
                          if (ctx.mounted &&
                              ModalRoute.of(ctx)?.isCurrent == true) {
                            Navigator.of(ctx).pop();
                          }
                          // The dialog may have been dismissed while the
                          // request was in flight: still report success.
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('空间已创建')),
                          );
                        } catch (e) {
                          if (!context.mounted) return;
                          // 账号可能在请求期间切换：跳过失败反馈（与成功路径一致），
                          // 并关闭卡在 in-flight 态的对话框。
                          if (container.read(activeUserIdProvider) !=
                              dialogAccountUserId) {
                            if (ctx.mounted &&
                                ModalRoute.of(ctx)?.isCurrent == true) {
                              Navigator.of(ctx).pop();
                            }
                            return;
                          }
                          if (ctx.mounted) {
                            setDialogState(() {
                              creating = false;
                              // Render the failure inside the dialog: a
                              // page-level snackbar would sit beneath the
                              // modal barrier while the dialog stays open.
                              createError = _actionFailureMessage(e);
                            });
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(_actionFailureMessage(e))),
                            );
                          }
                        }
                      },
                child: creating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          color: AppColors.secondary,
                          strokeWidth: 2,
                        ),
                      )
                    : const Text(
                        '创建',
                        style: TextStyle(color: AppColors.secondary),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showJoinSpaceDialog(BuildContext context) {
    // Account snapshot captured when the dialog OPENS: a switch while the
    // dialog is up must not redirect the write to the new account.
    final container = ProviderScope.containerOf(context, listen: false);
    final dialogAccountUserId = container.read(activeUserIdProvider) ?? '';
    var spaceIdentifier = '';
    var joining = false;
    String? joinError;
    // (The page-scoped container is captured at the top of this method.)
    showDialog(
      context: context,
      builder: (ctx) => Consumer(
        // `_` for the dialog-scoped context: the async closures below must
        // use the PAGE context (method parameter) so feedback still lands
        // after the dialog was dismissed mid-request.
        builder: (_, ref, _) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            backgroundColor: AppColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.surface),
            ),
            title: const Text(
              '加入空间',
              style: TextStyle(color: AppColors.onBackground),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  onChanged: (value) => spaceIdentifier = value,
                  style: const TextStyle(color: AppColors.onBackground),
                  decoration: const InputDecoration(
                    hintText: '!space_id:server 或 #alias:server',
                    hintStyle: TextStyle(color: AppColors.onSurfaceVariant),
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
                        final value = spaceIdentifier.trim();
                        if (value.isEmpty) {
                          // Feedback instead of a silent no-op (same
                          // discipline as the create-space dialog).
                          setDialogState(() => joinError = '请输入空间 ID 或别名');
                          return;
                        }
                        setDialogState(() {
                          joining = true;
                          joinError = null;
                        });
                        try {
                          await joinRoom(
                            // Account snapshot captured when the dialog
                            // OPENED (see above), not read at tap time.
                            accountUserId: dialogAccountUserId,
                            identifier: value,
                          );
                          // The account may have switched while the request
                          // was in flight: skip ALL local feedback (same
                          // discipline as the other pages) and close the
                          // dialog — it would otherwise stay stuck in its
                          // in-flight state above the new account's page.
                          if (container.read(activeUserIdProvider) !=
                              dialogAccountUserId) {
                            if (ctx.mounted &&
                                ModalRoute.of(ctx)?.isCurrent == true) {
                              Navigator.of(ctx).pop();
                            }
                            return;
                          }
                          // Page-scoped container: the dialog-scoped ref is
                          // disposed (and would throw) once the dialog was
                          // dismissed mid-request.
                          container.invalidate(spacesProvider);
                          container.invalidate(chatRoomsProvider);
                          container.invalidate(ungroupedRoomsProvider);
                          if (!context.mounted) return;
                          // `isCurrent` guards against popping the page when
                          // the dialog was dismissed during its exit
                          // transition (mounted stays true through it).
                          if (ctx.mounted &&
                              ModalRoute.of(ctx)?.isCurrent == true) {
                            Navigator.of(ctx).pop();
                          }
                          // The dialog may have been dismissed while the
                          // request was in flight: still report success.
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已加入空间')),
                          );
                        } catch (e) {
                          if (!context.mounted) return;
                          // 账号可能在请求期间切换：跳过失败反馈（与成功路径一致），
                          // 并关闭卡在 in-flight 态的对话框。
                          if (container.read(activeUserIdProvider) !=
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
                              // modal barrier while the dialog stays open.
                              joinError = _actionFailureMessage(e);
                            });
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(_actionFailureMessage(e))),
                            );
                          }
                        }
                      },
                child: joining
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          color: AppColors.secondary,
                          strokeWidth: 2,
                        ),
                      )
                    : const Text(
                        '加入',
                        style: TextStyle(color: AppColors.secondary),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SpaceRoomTile extends StatelessWidget {
  final Space space;

  const _SpaceRoomTile({super.key, required this.space});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.surface),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => SpaceDetailPage(space: space)),
          );
        },
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadii.surface),
          ),
          child: Row(
            children: [
              AppAvatar(fallback: space.name, size: 48, url: space.avatarUrl),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      space.name,
                      style: const TextStyle(
                        color: AppColors.onBackground,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '查看房间、成员和空间设置',
                      style: const TextStyle(
                        color: AppColors.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                color: AppColors.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;

  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surfaceElevated,
          borderRadius: BorderRadius.circular(AppRadii.surface),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: AppColors.onBackground,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: const TextStyle(
                color: AppColors.onSurfaceVariant,
                fontSize: 13,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

class _HintText extends StatelessWidget {
  final String text;

  const _HintText(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: AppColors.onSurfaceVariant,
        fontSize: 13,
        height: 1.4,
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.surface),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: AppColors.secondary, size: 22),
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
          ],
        ),
      ),
    );
  }
}
