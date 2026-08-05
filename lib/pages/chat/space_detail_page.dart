import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/max_content_width.dart';
import 'action_failure_message.dart';
import 'chat_detail_page.dart';

/// Guard wording shown inside the space dialogs while a previous space
/// write is still in flight. Kept as a constant so the dialogs can render
/// it in a neutral color (it is a notice, not an error) and clear it once
/// the guard passes.
const _spaceBusyTip = '正在处理空间操作，请稍候';

class SpaceDetailPage extends ConsumerStatefulWidget {
  final Space space;

  const SpaceDetailPage({super.key, required this.space});

  @override
  ConsumerState<SpaceDetailPage> createState() => _SpaceDetailPageState();
}

class _SpaceDetailPageState extends ConsumerState<SpaceDetailPage> {
  /// The account this page was opened under. Switching away shows the
  /// neutral placeholder and drops the actions (same discipline as the
  /// room management and pinned pages): without it, the header (space
  /// details) would keep the old account's data while the child list
  /// refreshes under the new account, and actions would write to the new
  /// account.
  String? _openedUserId;
  bool _accountSwitched = false;

  /// Room currently being added to this space (double-tap guard: the sheet
  /// is a separate route, so its rows cannot be disabled by a page-level
  /// setState — the guard intercepts the second tap instead).
  String? _addingToSpaceRoomId;

  /// The add-room sheet's context while it is open (null once it closes):
  /// an account switch must dismiss the sheet through it, or the sheet
  /// would hover over the "account switched" placeholder and keep
  /// accepting taps for the previous account.
  BuildContext? _addRoomSheetContext;

  /// A space-level write (edit/remove/leave confirmations) is in flight:
  /// double-tap guard for the dialog confirm buttons (the dialogs are
  /// separate routes, so a page-level setState cannot disable their
  /// buttons — the guard intercepts the second tap instead).
  bool _spaceActionInProgress = false;

  bool _accountActive() =>
      mounted && ref.read(activeUserIdProvider) == _openedUserId;

  /// Map a failed write's error to the unified timeout/partial-success
  /// wording (same discipline as the room management page): a queue-wait
  /// timeout means the write may still be landing in its background tail,
  /// and a partially-succeeded outcome is not a plain failure.
  String _actionFailureMessage(Object error) => actionFailureMessage(error);

  @override
  void initState() {
    super.initState();
    _openedUserId = ref.read(activeUserIdProvider);
    ref.listenManual(activeUserIdProvider, (_, next) {
      if (!mounted) return;
      if (_openedUserId == null && next != null) {
        // Opened before login completed: adopt the first account instead
        // of showing the placeholder forever.
        _openedUserId = next;
        setState(() => _accountSwitched = false);
        return;
      }
      final switched = next != _openedUserId;
      if (switched) {
        // Dismiss an open add-room sheet: it must not hover over the
        // placeholder or accept writes for the previous account. `isCurrent`
        // guard: another modal may sit above the sheet — popping then would
        // dismiss that dialog instead.
        final sheetContext = _addRoomSheetContext;
        if (sheetContext != null &&
            sheetContext.mounted &&
            ModalRoute.of(sheetContext)?.isCurrent == true) {
          Navigator.of(sheetContext).pop();
        }
      }
      setState(() => _accountSwitched = switched);
    });
  }

  @override
  Widget build(BuildContext context) {
    final space = widget.space;
    if (_accountSwitched || !_accountActive()) {
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
            '空间',
            style: TextStyle(
              color: AppColors.onBackground,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        body: const Center(
          child: Text(
            '账号已切换',
            style: TextStyle(color: AppColors.onSurfaceVariant),
          ),
        ),
      );
    }
    final detailsAsync = ref.watch(spaceDetailsProvider(space.id));
    final membersAsync = ref.watch(roomMembersProvider(space.id));
    final childrenAsync = ref.watch(spaceChildrenProvider(space.id));
    final fallbackDetails = SpaceDetails(
      id: space.id,
      name: space.name,
      avatarUrl: space.avatarUrl,
      topic: null,
    );
    final details = detailsAsync.maybeWhen(
      data: (value) => value,
      orElse: () => fallbackDetails,
    );

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
          '空间',
          style: TextStyle(
            color: AppColors.onBackground,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(
              Icons.playlist_add_rounded,
              color: AppColors.onBackground,
            ),
            onPressed: () => _showAddRoomDialog(context, ref),
          ),
          PopupMenuButton<_SpaceMenuAction>(
            color: AppColors.surface,
            icon: const Icon(
              Icons.more_horiz_rounded,
              color: AppColors.onBackground,
            ),
            onSelected: (action) {
              switch (action) {
                case _SpaceMenuAction.edit:
                  _showEditSpaceDialog(context, ref, details);
                case _SpaceMenuAction.leave:
                  _confirmLeaveSpace(context, ref, details);
              }
            },
            // Editing needs the loaded details: with the fallback (loading /
            // failed fetch) the dialog would prefill an empty topic and
            // saving would silently clear the server-side topic.
            itemBuilder: (context) => [
              PopupMenuItem(
                value: _SpaceMenuAction.edit,
                enabled: detailsAsync.hasValue,
                child: const Text('编辑空间'),
              ),
              const PopupMenuItem(
                value: _SpaceMenuAction.leave,
                child: Text('退出空间'),
              ),
            ],
          ),
        ],
      ),
      body: MaxContentWidth(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(AppRadii.surface),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      AppAvatar(
                        fallback: details.name,
                        size: 56,
                        radius: AppRadii.content,
                        url: details.avatarUrl,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              details.name,
                              style: const TextStyle(
                                color: AppColors.onBackground,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              details.id,
                              style: const TextStyle(
                                color: AppColors.onSurfaceVariant,
                                fontSize: 12.5,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if ((details.topic ?? '').isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Text(
                      details.topic!,
                      style: const TextStyle(
                        color: AppColors.onSurfaceVariant,
                        fontSize: 13.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            _Section(
              title: '房间列表',
              child: childrenAsync.when(
                data: (rooms) {
                  if (rooms.isEmpty) {
                    return const Text(
                      '这个空间下暂时没有可见房间',
                      style: TextStyle(
                        color: AppColors.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    );
                  }
                  return Column(
                    children: [
                      for (final room in rooms)
                        _SpaceChildTile(
                          room: room,
                          onRemove: room.roomType == 'space'
                              ? null
                              : () => _confirmRemoveRoom(context, ref, room),
                        ),
                    ],
                  );
                },
                loading: () => const Center(
                  child: CircularProgressIndicator(
                    color: AppColors.primary,
                    strokeWidth: 2,
                  ),
                ),
                error: (err, _) => Text(
                  '加载房间失败: $err',
                  style: const TextStyle(
                    color: AppColors.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _Section(
              title: '成员',
              child: membersAsync.when(
                data: (members) {
                  if (members.isEmpty) {
                    return const Text(
                      '暂无成员信息',
                      style: TextStyle(
                        color: AppColors.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    );
                  }
                  return Column(
                    children: [
                      for (final member in members.take(8))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Row(
                            children: [
                              AppAvatar(
                                fallback: member.name,
                                size: 36,
                                radius: AppRadii.content,
                                url: member.avatarUrl,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  member.name,
                                  style: const TextStyle(
                                    color: AppColors.onBackground,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (members.length > 8)
                        Text(
                          '还有 ${members.length - 8} 位成员',
                          style: const TextStyle(
                            color: AppColors.onSurfaceVariant,
                            fontSize: 12.5,
                          ),
                        ),
                    ],
                  );
                },
                loading: () => const Center(
                  child: CircularProgressIndicator(
                    color: AppColors.primary,
                    strokeWidth: 2,
                  ),
                ),
                error: (err, _) => Text(
                  '加载成员失败: $err',
                  style: const TextStyle(
                    color: AppColors.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _Section(
              title: '设置',
              child: Column(
                children: [
                  _ActionSettingRow(
                    icon: Icons.edit_rounded,
                    label: '编辑空间',
                    value: '修改名称与说明',
                    onTap: () => _showEditSpaceDialog(context, ref, details),
                  ),
                  const SizedBox(height: 10),
                  _ActionSettingRow(
                    icon: Icons.exit_to_app_rounded,
                    label: '退出空间',
                    value: '离开当前空间',
                    danger: true,
                    onTap: () => _confirmLeaveSpace(context, ref, details),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditSpaceDialog(
    BuildContext context,
    WidgetRef ref,
    SpaceDetails details,
  ) {
    final nameController = TextEditingController(text: details.name);
    final topicController = TextEditingController(text: details.topic ?? '');
    String? editError;
    var saving = false;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.surface),
          ),
          title: const Text(
            '编辑空间',
            style: TextStyle(color: AppColors.onBackground),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                style: const TextStyle(color: AppColors.onBackground),
                decoration: const InputDecoration(
                  hintText: '空间名称',
                  hintStyle: TextStyle(color: AppColors.onSurfaceVariant),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: topicController,
                minLines: 2,
                maxLines: 4,
                style: const TextStyle(color: AppColors.onBackground),
                decoration: const InputDecoration(
                  hintText: '空间说明',
                  hintStyle: TextStyle(color: AppColors.onSurfaceVariant),
                ),
              ),
              if (editError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    editError!,
                    style: TextStyle(
                      color: editError == _spaceBusyTip
                          ? AppColors.onSurfaceVariant
                          : AppColors.error,
                      fontSize: 13,
                    ),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text(
                '取消',
                style: TextStyle(color: AppColors.onSurfaceVariant),
              ),
            ),
            TextButton(
              onPressed: () async {
                // Entry guard: the dialog does not rebuild on a page-level
                // setState, so a second tap would otherwise issue a duplicate
                // write.
                if (_spaceActionInProgress) {
                  // The previous request may still be in flight (its dialog
                  // was dismissed): say so instead of silently swallowing the
                  // tap (same discipline as the leave dialog). Render inside
                  // the dialog: a page snackbar would sit beneath the modal
                  // barrier and stay invisible.
                  setDialogState(() => editError = _spaceBusyTip);
                  return;
                }
                // The busy tip may linger from a previous dismissal: clear it
                // once the guard passes.
                if (editError == _spaceBusyTip) {
                  setDialogState(() => editError = null);
                }
                final name = nameController.text.trim();
                final topic = topicController.text.trim();
                // Validate BEFORE arming the guard: an early return here must
                // not strand the flag (every later confirm would be blocked).
                if (name.isEmpty) {
                  // Feedback instead of a silent no-op (same as the room
                  // management save path).
                  setDialogState(() => editError = '空间名称不能为空');
                  return;
                }
                _spaceActionInProgress = true;
                if (dialogContext.mounted) {
                  setDialogState(() => saving = true);
                }
                try {
                  await updateSpaceDetails(
                    accountUserId: _openedUserId ?? '',
                    spaceId: details.id,
                    name: name,
                    topic: topic.isEmpty ? null : topic,
                  );
                  // The account may have switched while the request was in
                  // flight: the page shows the switched placeholder — skip
                  // the local bookkeeping (same discipline as the other
                  // pages).
                  if (!_accountActive()) {
                    // Close the dialog: it would otherwise hover over the
                    // switched placeholder (same as the catch branch).
                    if (dialogContext.mounted &&
                        ModalRoute.of(dialogContext)?.isCurrent == true) {
                      Navigator.of(dialogContext).pop();
                    }
                    return;
                  }
                  ref.invalidate(spaceDetailsProvider(details.id));
                  ref.invalidate(spacesProvider);
                  ref.invalidate(chatRoomsProvider);
                  if (!context.mounted) return;
                  // `isCurrent` guard: the dialog may have been dismissed
                  // during its exit animation — popping then would pop the
                  // PAGE below it.
                  if (dialogContext.mounted &&
                      ModalRoute.of(dialogContext)?.isCurrent == true) {
                    Navigator.of(dialogContext).pop();
                  }
                  // The dialog may have been dismissed while the request was
                  // in flight: still report success.
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('空间已更新')));
                } catch (e) {
                  if (!context.mounted) return;
                  // 账号可能在请求期间切换：跳过失败反馈（与成功路径一致），并
                  // 关闭对话框——它停留的旧账号内容已无意义，且重试只会再次被
                  // Rust 账号守卫拒绝（无反馈）。
                  if (!_accountActive()) {
                    if (dialogContext.mounted &&
                        ModalRoute.of(dialogContext)?.isCurrent == true) {
                      Navigator.of(dialogContext).pop();
                    }
                    return;
                  }
                  // The name write may have succeeded before a later topic
                  // write failed. Refresh the affected views even on errors
                  // so the UI reflects the server's partial result.
                  ref.invalidate(spaceDetailsProvider(details.id));
                  ref.invalidate(spacesProvider);
                  ref.invalidate(chatRoomsProvider);
                  if (dialogContext.mounted) {
                    // Render the failure inside the dialog: a page-level
                    // snackbar would sit beneath the modal barrier and stay
                    // invisible while the dialog stays open for retry.
                    setDialogState(() => editError = _actionFailureMessage(e));
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(_actionFailureMessage(e))),
                    );
                  }
                } finally {
                  if (mounted) _spaceActionInProgress = false;
                  if (dialogContext.mounted) {
                    setDialogState(() => saving = false);
                  }
                }
              },
              child: saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        color: AppColors.secondary,
                        strokeWidth: 2,
                      ),
                    )
                  : const Text(
                      '保存',
                      style: TextStyle(color: AppColors.secondary),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddRoomDialog(BuildContext context, WidgetRef ref) {
    // The Consumer below shadows [context] with the sheet's own context,
    // which is unmounted as soon as the sheet route is dismissed. Keep the
    // page context here: the write may outlive an early dismissal (barrier
    // tap / swipe while it is in flight), and its success/failure must
    // still be reported on the page.
    final pageContext = context;
    // Container-level invalidates: the sheet's own `ref` throws once the
    // sheet is dismissed (Riverpod asserts on disposed widgets), and the
    // write can outlive an early dismissal.
    final container = ProviderScope.containerOf(pageContext, listen: false);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      // Watch the ungrouped list inside the sheet: a loading or error
      // state must not masquerade as "no rooms" (the previous read-once
      // snapshot did).
      builder: (sheetContext) => Consumer(
        builder: (context, ref, _) {
          // Track the sheet's context (the Consumer's own): an account
          // switch dismisses the sheet through it (see the
          // activeUserIdProvider listener).
          _addRoomSheetContext = context;
          final ungroupedAsync = ref.watch(ungroupedRoomsProvider);
          return Container(
            margin: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadii.surface),
            ),
            child: SafeArea(
              child: ungroupedAsync.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
                error: (error, _) => Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        '加载可加入的房间失败',
                        style: TextStyle(color: AppColors.error, fontSize: 13),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: () => ref.invalidate(ungroupedRoomsProvider),
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
                data: (rooms) => rooms.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(20),
                        child: Text(
                          '当前没有可加入这个空间的未归属群组。',
                          style: TextStyle(
                            color: AppColors.onSurfaceVariant,
                            fontSize: 13,
                          ),
                        ),
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final room in rooms)
                            ListTile(
                              title: Text(
                                room.name,
                                style: const TextStyle(
                                  color: AppColors.onBackground,
                                ),
                              ),
                              subtitle: Text(
                                room.lastMessage.isEmpty
                                    ? room.id
                                    : room.lastMessage,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: AppColors.onSurfaceVariant,
                                  fontSize: 12.5,
                                ),
                              ),
                              trailing: const Icon(
                                Icons.add_link_rounded,
                                color: AppColors.secondary,
                              ),
                              onTap: _addingToSpaceRoomId == room.id
                                  ? null
                                  : () async {
                                      // Entry guard (not only the disabled
                                      // row): the sheet does not rebuild on
                                      // a page-level setState, so a second
                                      // tap on the old row would otherwise
                                      // issue a duplicate add.
                                      if (!_accountActive()) return;
                                      if (_addingToSpaceRoomId != null) {
                                        // Say so instead of silently
                                        // swallowing the tap (same
                                        // discipline as the other guards). A
                                        // snackbar on the sheet context would
                                        // render beneath the sheet barrier,
                                        // so close the sheet first and
                                        // report on the page (same as the
                                        // failure path). `isCurrent` guard:
                                        // the account-switch listener may
                                        // already be popping the sheet.
                                        if (sheetContext.mounted &&
                                            ModalRoute.of(
                                                  sheetContext,
                                                )?.isCurrent ==
                                                true) {
                                          Navigator.of(sheetContext).pop();
                                        }
                                        ScaffoldMessenger.of(
                                          pageContext,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text('正在添加房间，请稍候'),
                                          ),
                                        );
                                        return;
                                      }
                                      _addingToSpaceRoomId = room.id;
                                      try {
                                        await addRoomToSpace(
                                          accountUserId: _openedUserId ?? '',
                                          spaceId: widget.space.id,
                                          roomId: room.id,
                                        );
                                        // The account may have switched
                                        // while the request was in flight:
                                        // the page shows the switched
                                        // placeholder — skip the local
                                        // bookkeeping.
                                        if (!_accountActive()) return;
                                        // Container-level invalidates: the
                                        // sheet's own `ref` would throw if
                                        // the sheet was dismissed while the
                                        // write was in flight.
                                        container.invalidate(
                                          spaceChildrenProvider(
                                            widget.space.id,
                                          ),
                                        );
                                        container.invalidate(
                                          ungroupedRoomsProvider,
                                        );
                                        if (!pageContext.mounted) return;
                                        if (sheetContext.mounted &&
                                            ModalRoute.of(
                                                  sheetContext,
                                                )?.isCurrent ==
                                                true) {
                                          Navigator.of(sheetContext).pop();
                                        }
                                        // The sheet may have been dismissed
                                        // while the request was in flight:
                                        // still report success on the page.
                                        ScaffoldMessenger.of(
                                          pageContext,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text('已加入空间'),
                                          ),
                                        );
                                      } catch (e) {
                                        if (!pageContext.mounted) return;
                                        // 账号可能在请求期间切换：跳过失败反馈（与成功路径一致）。
                                        if (!_accountActive()) return;
                                        if (sheetContext.mounted &&
                                            ModalRoute.of(
                                                  sheetContext,
                                                )?.isCurrent ==
                                                true) {
                                          // Close the sheet first, then
                                          // report: a page snackbar while
                                          // the sheet is up would sit hidden
                                          // behind its barrier.
                                          Navigator.of(sheetContext).pop();
                                        }
                                        ScaffoldMessenger.of(
                                          pageContext,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              _actionFailureMessage(e),
                                            ),
                                          ),
                                        );
                                      } finally {
                                        if (mounted) {
                                          _addingToSpaceRoomId = null;
                                        }
                                      }
                                    },
                            ),
                        ],
                      ),
              ),
            ),
          );
        },
      ),
    ).whenComplete(() {
      _addRoomSheetContext = null;
    });
  }

  void _confirmRemoveRoom(BuildContext context, WidgetRef ref, ChatRoom room) {
    String? removeError;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.surface),
          ),
          title: const Text(
            '移出空间',
            style: TextStyle(color: AppColors.onBackground),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '要把“${room.name}”从这个空间移除吗？',
                style: const TextStyle(color: AppColors.onBackground),
              ),
              if (removeError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    removeError!,
                    style: TextStyle(
                      color: removeError == _spaceBusyTip
                          ? AppColors.onSurfaceVariant
                          : AppColors.error,
                      fontSize: 13,
                    ),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text(
                '取消',
                style: TextStyle(color: AppColors.onSurfaceVariant),
              ),
            ),
            TextButton(
              onPressed: () async {
                // Entry guard: the dialog does not rebuild on a page-level
                // setState, so a second tap would otherwise issue a duplicate
                // removal.
                if (_spaceActionInProgress) {
                  // The previous request may still be in flight (its dialog
                  // was dismissed): say so instead of silently swallowing the
                  // tap (same discipline as the leave dialog). Render inside
                  // the dialog: a page snackbar would sit beneath the modal
                  // barrier and stay invisible.
                  setDialogState(() => removeError = _spaceBusyTip);
                  return;
                }
                // The busy tip may linger from a previous dismissal: clear it
                // once the guard passes.
                if (removeError == _spaceBusyTip) {
                  setDialogState(() => removeError = null);
                }
                _spaceActionInProgress = true;
                try {
                  await removeRoomFromSpace(
                    accountUserId: _openedUserId ?? '',
                    spaceId: widget.space.id,
                    roomId: room.id,
                  );
                  // The account may have switched while the request was in
                  // flight: the page shows the switched placeholder — skip
                  // the local bookkeeping and close the dialog (same as the
                  // catch branch).
                  if (!_accountActive()) {
                    if (dialogContext.mounted &&
                        ModalRoute.of(dialogContext)?.isCurrent == true) {
                      Navigator.of(dialogContext).pop();
                    }
                    return;
                  }
                  // `context.mounted` first: `ref.invalidate` throws once
                  // the page is unmounted (the dialog may have been closed
                  // and the page popped while the write was in flight).
                  if (!context.mounted) return;
                  ref.invalidate(spaceChildrenProvider(widget.space.id));
                  ref.invalidate(ungroupedRoomsProvider);
                  // `isCurrent` guard: the dialog may have been dismissed
                  // during its exit animation — popping then would pop the
                  // PAGE below it.
                  if (dialogContext.mounted &&
                      ModalRoute.of(dialogContext)?.isCurrent == true) {
                    Navigator.of(dialogContext).pop();
                  }
                  // The dialog may have been dismissed while the request was
                  // in flight: still report success.
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('已从空间移除')));
                } catch (e) {
                  if (!context.mounted) return;
                  // 账号可能在请求期间切换：跳过失败反馈（与成功路径一致），并
                  // 关闭对话框——它停留的旧账号内容已无意义，且重试只会再次被
                  // Rust 账号守卫拒绝（无反馈）。
                  if (!_accountActive()) {
                    if (dialogContext.mounted &&
                        ModalRoute.of(dialogContext)?.isCurrent == true) {
                      Navigator.of(dialogContext).pop();
                    }
                    return;
                  }
                  if (dialogContext.mounted) {
                    // Render the failure inside the dialog: a page-level
                    // snackbar would sit beneath the modal barrier and stay
                    // invisible while the dialog stays open for retry.
                    setDialogState(
                      () => removeError = _actionFailureMessage(e),
                    );
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(_actionFailureMessage(e))),
                    );
                  }
                } finally {
                  if (mounted) _spaceActionInProgress = false;
                }
              },
              child: const Text('移除', style: TextStyle(color: AppColors.error)),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmLeaveSpace(
    BuildContext context,
    WidgetRef ref,
    SpaceDetails details,
  ) {
    String? leaveSpaceError;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.surface),
          ),
          title: const Text(
            '退出空间',
            style: TextStyle(color: AppColors.onBackground),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '确认退出“${details.name}”吗？',
                style: const TextStyle(color: AppColors.onBackground),
              ),
              if (leaveSpaceError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    leaveSpaceError!,
                    style: TextStyle(
                      color: leaveSpaceError == _spaceBusyTip
                          ? AppColors.onSurfaceVariant
                          : AppColors.error,
                      fontSize: 13,
                    ),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text(
                '取消',
                style: TextStyle(color: AppColors.onSurfaceVariant),
              ),
            ),
            TextButton(
              onPressed: () async {
                // Entry guard: the dialog does not rebuild on a page-level
                // setState, so a second tap would otherwise issue a duplicate
                // leave.
                if (_spaceActionInProgress) {
                  // The previous request may still be in flight (its dialog
                  // was dismissed): say so instead of silently swallowing the
                  // tap (same discipline as the leave dialog). Render inside
                  // the dialog: a page snackbar would sit beneath the modal
                  // barrier and stay invisible.
                  setDialogState(() => leaveSpaceError = _spaceBusyTip);
                  return;
                }
                // The busy tip may linger from a previous dismissal: clear it
                // once the guard passes.
                if (leaveSpaceError == _spaceBusyTip) {
                  setDialogState(() => leaveSpaceError = null);
                }
                _spaceActionInProgress = true;
                try {
                  await leaveSpace(
                    accountUserId: _openedUserId ?? '',
                    spaceId: details.id,
                  );
                  // The account may have switched while the request was in
                  // flight: the page shows the switched placeholder — skip
                  // the local bookkeeping and close the dialog (same as the
                  // catch branch).
                  if (!_accountActive()) {
                    if (dialogContext.mounted &&
                        ModalRoute.of(dialogContext)?.isCurrent == true) {
                      Navigator.of(dialogContext).pop();
                    }
                    return;
                  }
                  // `context.mounted` first: `ref.invalidate` throws once
                  // the page is unmounted (the dialog may have been closed
                  // and the page popped while the write was in flight).
                  if (!context.mounted) return;
                  ref.invalidate(spacesProvider);
                  ref.invalidate(chatRoomsProvider);
                  ref.invalidate(ungroupedRoomsProvider);
                  // `isCurrent` guard: the dialog may have been dismissed
                  // during its exit animation — popping then would pop the
                  // PAGE below it.
                  if (dialogContext.mounted &&
                      ModalRoute.of(dialogContext)?.isCurrent == true) {
                    Navigator.of(dialogContext).pop();
                  }
                  // The dialog may have been dismissed while the request was
                  // in flight: still close the page and report success.
                  if (mounted && ModalRoute.of(context)?.isCurrent == true) {
                    Navigator.of(context).pop();
                  }
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('已退出空间')));
                } catch (e) {
                  if (!context.mounted) return;
                  // 账号可能在请求期间切换：跳过失败反馈（与成功路径一致），并
                  // 关闭对话框——它停留的旧账号内容已无意义，且重试只会再次被
                  // Rust 账号守卫拒绝（无反馈）。
                  if (!_accountActive()) {
                    if (dialogContext.mounted &&
                        ModalRoute.of(dialogContext)?.isCurrent == true) {
                      Navigator.of(dialogContext).pop();
                    }
                    return;
                  }
                  if (dialogContext.mounted) {
                    // Render the failure inside the dialog: a page-level
                    // snackbar would sit beneath the modal barrier and stay
                    // invisible while the dialog stays open for retry.
                    setDialogState(
                      () => leaveSpaceError = _actionFailureMessage(e),
                    );
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(_actionFailureMessage(e))),
                    );
                  }
                } finally {
                  if (mounted) _spaceActionInProgress = false;
                }
              },
              child: const Text('退出', style: TextStyle(color: AppColors.error)),
            ),
          ],
        ),
      ),
    );
  }
}

enum _SpaceMenuAction { edit, leave }

class _Section extends StatelessWidget {
  final String title;
  final Widget child;

  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
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
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _SpaceChildTile extends ConsumerWidget {
  final ChatRoom room;
  final VoidCallback? onRemove;

  const _SpaceChildTile({required this.room, this.onRemove});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Match the main room list's unread display (override-aware), so a
    // marked-unread room never reads as "在线" inside a space, and pending
    // mark-read/unread writes show consistently during the echo window.
    final unreadOverride = ref.watch(roomUnreadOverrideProvider(room.id));
    final syncedHasUnread = room.unreadCount > 0 || room.isMarkedUnread;
    final overrideApplies = unreadOverride?.appliesTo(room) ?? false;
    final hasUnread = overrideApplies
        ? unreadOverride!.unread
        : syncedHasUnread;
    final unreadAccent = room.isMuted
        ? AppColors.onSurfaceVariant
        : AppColors.primary;
    // Same stale-override cleanup as the main room list: a room managed only
    // from the space view must not keep a dead override in memory. Only a
    // no-longer-applicable override is dropped.
    if (unreadOverride != null && !overrideApplies) {
      clearStaleRoomUnreadOverride(ref, context, room.id, unreadOverride);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.surface),
        onTap: () {
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
                      subtitle: hasUnread
                          ? (room.unreadCount > 0
                                ? '${room.unreadCount} 条未读消息'
                                : '已标记未读')
                          : '在线',
                    ),
            ),
          );
        },
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadii.surface),
          ),
          child: Row(
            children: [
              AppAvatar(fallback: room.name, size: 42, url: room.avatarUrl),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      room.name,
                      style: const TextStyle(
                        color: AppColors.onBackground,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      room.lastMessage.isEmpty ? room.id : room.lastMessage,
                      style: const TextStyle(
                        color: AppColors.onSurfaceVariant,
                        fontSize: 12.5,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (hasUnread) ...[
                const SizedBox(width: 8),
                if (room.unreadCount > 0)
                  Container(
                    key: ValueKey('space-child-unread-badge:${room.id}'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: unreadAccent,
                      borderRadius: BorderRadius.circular(AppRadii.tag),
                    ),
                    child: Text(
                      room.unreadCount > 99 ? '99+' : '${room.unreadCount}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  )
                else
                  Container(
                    key: ValueKey('space-child-unread-dot:${room.id}'),
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: unreadAccent,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
              if (onRemove != null)
                IconButton(
                  onPressed: onRemove,
                  icon: const Icon(
                    Icons.remove_circle_outline_rounded,
                    color: AppColors.error,
                  ),
                  tooltip: '从空间移除',
                )
              else
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

class _ActionSettingRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool danger;
  final VoidCallback onTap;

  const _ActionSettingRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.error : AppColors.onBackground;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadii.content),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(
              icon,
              color: danger ? AppColors.error : AppColors.onSurfaceVariant,
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Text(
              value,
              style: const TextStyle(
                color: AppColors.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
            const SizedBox(width: 6),
            const Icon(
              Icons.chevron_right_rounded,
              color: AppColors.onSurfaceVariant,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }
}
