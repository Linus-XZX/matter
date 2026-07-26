import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/app_theme.dart';
import '../../widgets/app_avatar.dart';
import '../settings/avatar_crop_editor_page.dart';
import 'pinned_messages_page.dart';

class RoomManagementPage extends ConsumerStatefulWidget {
  final String roomId;
  final String roomName;
  final String? avatarUrl;
  final VoidCallback? onRoomLeft;

  const RoomManagementPage({
    super.key,
    required this.roomId,
    required this.roomName,
    this.avatarUrl,
    this.onRoomLeft,
  });

  @override
  ConsumerState<RoomManagementPage> createState() => _RoomManagementPageState();
}

class _RoomManagementPageState extends ConsumerState<RoomManagementPage> {
  final _nameController = TextEditingController();
  final _topicController = TextEditingController();
  final _imagePicker = ImagePicker();
  rust.RoomDetails? _details;
  List<rust.Contact> _members = const [];
  List<rust.KnockRequest> _knockRequests = const [];
  List<String> _ignoredUsers = const [];
  Object? _mutedLoadError;
  Object? _membersLoadError;
  Object? _knocksLoadError;
  Object? _ignoredUsersLoadError;
  bool _muted = false;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _topicController.dispose();
    super.dispose();
  }

  Future<({T? value, Object? error})> _attempt<T>(Future<T> future) async {
    try {
      return (value: await future, error: null);
    } catch (error) {
      return (value: null, error: error);
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _mutedLoadError = null;
      _membersLoadError = null;
      _knocksLoadError = null;
      _ignoredUsersLoadError = null;
    });
    try {
      final details = await rust.getRoomDetails(roomId: widget.roomId);
      final mutedFuture = _attempt(rust.isRoomMuted(roomId: widget.roomId));
      final membersFuture = _attempt(
        rust.getRoomMembers(roomId: widget.roomId),
      );
      final knocksFuture = _attempt(
        rust.getRoomKnockRequests(roomId: widget.roomId),
      );
      final ignoredFuture = _attempt(rust.getIgnoredUsers());
      final muted = await mutedFuture;
      final members = await membersFuture;
      final knockRequests = await knocksFuture;
      final ignoredUsers = await ignoredFuture;
      if (!mounted) return;
      setState(() {
        _details = details;
        _mutedLoadError = muted.error;
        _membersLoadError = members.error;
        _knocksLoadError = knockRequests.error;
        _ignoredUsersLoadError = ignoredUsers.error;
        if (muted.value case final value?) _muted = value;
        if (members.value case final value?) _members = value;
        if (knockRequests.value case final value?) _knockRequests = value;
        if (ignoredUsers.value case final value?) _ignoredUsers = value;
        _nameController.text = details.hasExplicitName ? details.name : '';
        _topicController.text = details.topic ?? '';
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _retryPartialLoad<T>({
    required Future<T> Function() load,
    required void Function(T value) updateValue,
    required void Function(Object? error) updateError,
  }) async {
    final result = await _attempt(load());
    if (!mounted) return;
    setState(() {
      updateError(result.error);
      if (result.value case final value?) updateValue(value);
    });
  }

  Future<void> _retryMuted() => _retryPartialLoad(
    load: () => rust.isRoomMuted(roomId: widget.roomId),
    updateValue: (value) => _muted = value,
    updateError: (error) => _mutedLoadError = error,
  );

  Future<void> _retryMembers() => _retryPartialLoad(
    load: () => rust.getRoomMembers(roomId: widget.roomId),
    updateValue: (value) => _members = value,
    updateError: (error) => _membersLoadError = error,
  );

  Future<void> _retryKnocks() => _retryPartialLoad(
    load: () => rust.getRoomKnockRequests(roomId: widget.roomId),
    updateValue: (value) => _knockRequests = value,
    updateError: (error) => _knocksLoadError = error,
  );

  Future<void> _retryIgnoredUsers() => _retryPartialLoad(
    load: rust.getIgnoredUsers,
    updateValue: (value) => _ignoredUsers = value,
    updateError: (error) => _ignoredUsersLoadError = error,
  );

  void _invalidateRoom() {
    ref.invalidate(chatRoomsProvider);
    ref.invalidate(ungroupedRoomsProvider);
    ref.invalidate(roomMembersProvider(widget.roomId));
  }

  Future<void> _saveDetails() async {
    if (_saving) return;
    final details = _details;
    if (details == null) return;
    final name = _nameController.text.trim();
    if (details.hasExplicitName && name.isEmpty) {
      _showSnackBar('房间名称不能为空');
      return;
    }
    final updateName = details.hasExplicitName
        ? name != details.name
        : name.isNotEmpty;
    setState(() => _saving = true);
    try {
      await rust.updateRoomDetails(
        roomId: widget.roomId,
        name: name,
        updateName: updateName,
        topic: _topicController.text.trim().isEmpty
            ? null
            : _topicController.text.trim(),
      );
      _invalidateRoom();
      await _load();
      if (mounted) _showSnackBar('房间信息已更新');
    } catch (error) {
      if (mounted) _showSnackBar('更新失败: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickAvatar() async {
    if (_saving) return;
    try {
      final picked = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 95,
      );
      if (picked == null || !mounted) return;
      final sourceBytes = await picked.readAsBytes();
      if (!mounted) return;
      final bytes = await Navigator.of(context).push<Uint8List>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => AvatarCropEditorPage(imageBytes: sourceBytes),
        ),
      );
      if (bytes == null || !mounted) return;
      setState(() => _saving = true);
      await rust.uploadRoomAvatar(
        roomId: widget.roomId,
        contentType: 'image/jpeg',
        data: bytes,
      );
      _invalidateRoom();
      await _load();
      if (mounted) _showSnackBar('房间头像已更新');
    } catch (error) {
      if (mounted) _showSnackBar('头像更新失败: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _setMuted(bool muted) async {
    setState(() => _muted = muted);
    try {
      await rust.setRoomMuted(roomId: widget.roomId, muted: muted);
      if (mounted) _showSnackBar(muted ? '已开启免打扰' : '已关闭免打扰');
    } catch (error) {
      if (mounted) {
        setState(() => _muted = !muted);
        _showSnackBar('通知设置更新失败: $error');
      }
    }
  }

  void _showInviteDialog() {
    final controller = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          '邀请用户',
          style: TextStyle(color: AppColors.onBackground),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: AppColors.onBackground),
          decoration: const InputDecoration(
            hintText: '@user:server.example',
            hintStyle: TextStyle(color: AppColors.onSurfaceVariant),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              final userId = controller.text.trim();
              if (userId.isEmpty) return;
              try {
                await rust.inviteUserToRoom(
                  roomId: widget.roomId,
                  userId: userId,
                );
                _invalidateRoom();
                if (!dialogContext.mounted) return;
                Navigator.of(dialogContext).pop();
                _showSnackBar('邀请已发送');
              } catch (error) {
                if (dialogContext.mounted) {
                  _showSnackBar('邀请失败: $error');
                }
              }
            },
            child: const Text('邀请'),
          ),
        ],
      ),
    );
  }

  Future<void> _setUserIgnored(String userId, bool ignored) async {
    try {
      await rust.setUserIgnored(userId: userId, ignored: ignored);
      ref.invalidate(ignoredUserIdsProvider);
      ref.invalidate(messagesProvider(widget.roomId));
      await _load();
      if (mounted) _showSnackBar(ignored ? '已忽略 $userId' : '已取消忽略 $userId');
    } catch (error) {
      if (mounted) _showSnackBar('操作失败: $error');
    }
  }

  void _showIgnoredUsers() {
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
          child: _ignoredUsers.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    '暂无已忽略用户',
                    style: TextStyle(color: AppColors.onSurfaceVariant),
                  ),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _ignoredUsers.length,
                  separatorBuilder: (_, _) =>
                      const Divider(color: AppColors.surfaceVariant, height: 1),
                  itemBuilder: (context, index) {
                    final userId = _ignoredUsers[index];
                    return ListTile(
                      title: Text(
                        userId,
                        style: const TextStyle(color: AppColors.onBackground),
                      ),
                      trailing: IconButton(
                        tooltip: '取消忽略',
                        icon: const Icon(
                          Icons.person_add_alt_rounded,
                          color: AppColors.primary,
                        ),
                        onPressed: () async {
                          await _setUserIgnored(userId, false);
                          if (sheetContext.mounted) {
                            Navigator.of(sheetContext).pop();
                          }
                        },
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }

  Future<void> _runKnockAction(rust.KnockRequest request, bool approve) async {
    try {
      if (approve) {
        await rust.approveRoomKnock(
          roomId: widget.roomId,
          userId: request.userId,
        );
      } else {
        await rust.rejectRoomKnock(
          roomId: widget.roomId,
          userId: request.userId,
        );
      }
      _invalidateRoom();
      await _load();
      if (mounted) _showSnackBar(approve ? '已批准加入请求' : '已拒绝加入请求');
    } catch (error) {
      if (mounted) _showSnackBar('操作失败: $error');
    }
  }

  void _confirmLeave() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          '退出房间',
          style: TextStyle(color: AppColors.onBackground),
        ),
        content: const Text(
          '退出后将无法继续接收此房间的新消息。',
          style: TextStyle(color: AppColors.onSurface),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              try {
                await rust.leaveRoom(roomId: widget.roomId);
                _invalidateRoom();
                if (!dialogContext.mounted || !mounted) return;
                Navigator.of(dialogContext).pop();
                widget.onRoomLeft?.call();
                Navigator.of(context).popUntil((route) => route.isFirst);
              } catch (error) {
                if (dialogContext.mounted) _showSnackBar('退出失败: $error');
              }
            },
            child: const Text('退出', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final details = _details;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text(
          '房间管理',
          style: TextStyle(
            color: AppColors.onBackground,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '保存房间信息',
            onPressed: details == null || _saving ? null : _saveDetails,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(
                color: AppColors.primary,
                strokeWidth: 2,
              ),
            )
          : _error != null
          ? Center(
              child: TextButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded),
                label: Text('加载失败: $_error'),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                _section(
                  title: '房间信息',
                  child: Column(
                    children: [
                      Center(
                        child: Stack(
                          children: [
                            AppAvatar(
                              fallback: details!.name,
                              size: 76,
                              radius: AppRadii.content,
                              url: details.avatarUrl,
                            ),
                            Positioned(
                              right: -4,
                              bottom: -4,
                              child: IconButton.filled(
                                tooltip: '修改房间头像',
                                onPressed: _saving ? null : _pickAvatar,
                                icon: const Icon(Icons.edit_rounded, size: 18),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      TextField(
                        controller: _nameController,
                        style: const TextStyle(color: AppColors.onBackground),
                        decoration: const InputDecoration(labelText: '房间名称'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _topicController,
                        minLines: 2,
                        maxLines: 4,
                        style: const TextStyle(color: AppColors.onBackground),
                        decoration: const InputDecoration(labelText: '房间主题'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _section(
                  title: _membersLoadError == null
                      ? '成员 ${_members.length}'
                      : '成员',
                  action: IconButton(
                    tooltip: '邀请用户',
                    icon: const Icon(Icons.person_add_alt_1_rounded),
                    onPressed: _showInviteDialog,
                  ),
                  child: _membersLoadError != null
                      ? _partialLoadErrorTile(
                          label: '无法加载成员',
                          onRetry: _retryMembers,
                        )
                      : Column(
                          children: [
                            for (final member in _members) _memberTile(member),
                          ],
                        ),
                ),
                if (_knocksLoadError != null || _knockRequests.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _section(
                    title: _knocksLoadError == null
                        ? '加入请求 ${_knockRequests.length}'
                        : '加入请求',
                    child: _knocksLoadError != null
                        ? _partialLoadErrorTile(
                            label: '无法加载加入请求',
                            onRetry: _retryKnocks,
                          )
                        : Column(
                            children: [
                              for (final request in _knockRequests)
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: AppAvatar(
                                    fallback: request.displayName,
                                    size: 40,
                                    radius: 20,
                                    url: request.avatarUrl,
                                  ),
                                  title: Text(
                                    request.displayName,
                                    style: const TextStyle(
                                      color: AppColors.onBackground,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  subtitle: Text(
                                    request.reason?.isNotEmpty == true
                                        ? '${request.userId}\n${request.reason}'
                                        : request.userId,
                                    style: const TextStyle(
                                      color: AppColors.onSurfaceVariant,
                                      fontSize: 12,
                                    ),
                                  ),
                                  isThreeLine:
                                      request.reason?.isNotEmpty == true,
                                  trailing: Wrap(
                                    spacing: 2,
                                    children: [
                                      IconButton(
                                        tooltip: '批准',
                                        icon: const Icon(
                                          Icons.check_rounded,
                                          color: AppColors.primary,
                                        ),
                                        onPressed: () =>
                                            _runKnockAction(request, true),
                                      ),
                                      IconButton(
                                        tooltip: '拒绝',
                                        icon: const Icon(
                                          Icons.close_rounded,
                                          color: AppColors.error,
                                        ),
                                        onPressed: () =>
                                            _runKnockAction(request, false),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                  ),
                ],
                const SizedBox(height: 16),
                _section(
                  title: '通知与消息',
                  child: Column(
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          '免打扰',
                          style: TextStyle(color: AppColors.onBackground),
                        ),
                        subtitle: Text(
                          _mutedLoadError == null ? '不接收此房间的推送通知' : '无法加载通知设置',
                          style: const TextStyle(
                            color: AppColors.onSurfaceVariant,
                          ),
                        ),
                        value: _muted,
                        onChanged: _mutedLoadError == null ? _setMuted : null,
                        secondary: _mutedLoadError == null
                            ? null
                            : IconButton(
                                tooltip: '重试',
                                icon: const Icon(Icons.refresh_rounded),
                                onPressed: _retryMuted,
                              ),
                      ),
                      _actionTile(
                        icon: Icons.push_pin_rounded,
                        label: '置顶消息',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => PinnedMessagesPage(
                              roomId: widget.roomId,
                              roomName: details.name,
                            ),
                          ),
                        ),
                      ),
                      _actionTile(
                        icon: Icons.done_all_rounded,
                        label: '标记为已读',
                        onTap: () async {
                          try {
                            await rust.markRoomAsRead(roomId: widget.roomId);
                            _invalidateRoom();
                            if (mounted) _showSnackBar('已标记为已读');
                          } catch (error) {
                            if (mounted) _showSnackBar('操作失败: $error');
                          }
                        },
                      ),
                      _actionTile(
                        icon: Icons.mark_unread_chat_alt_rounded,
                        label: '标记为未读',
                        onTap: () async {
                          try {
                            await rust.markRoomUnread(roomId: widget.roomId);
                            _invalidateRoom();
                            if (mounted) _showSnackBar('已标记为未读');
                          } catch (error) {
                            if (mounted) _showSnackBar('操作失败: $error');
                          }
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _section(
                  title: '隐私',
                  child: _actionTile(
                    icon: _ignoredUsersLoadError == null
                        ? Icons.block_rounded
                        : Icons.refresh_rounded,
                    label: _ignoredUsersLoadError == null
                        ? '已忽略用户 (${_ignoredUsers.length})'
                        : '无法加载已忽略用户',
                    onTap: _ignoredUsersLoadError == null
                        ? _showIgnoredUsers
                        : _retryIgnoredUsers,
                  ),
                ),
                const SizedBox(height: 16),
                _section(
                  title: '危险操作',
                  child: _actionTile(
                    icon: Icons.exit_to_app_rounded,
                    label: '退出房间',
                    danger: true,
                    onTap: _confirmLeave,
                  ),
                ),
              ],
            ),
    );
  }

  Widget _memberTile(rust.Contact member) {
    final activeUserId = ref.read(activeUserIdProvider);
    final isCurrentUser = member.id == activeUserId;
    final ignored = _ignoredUsers.contains(member.id);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: AppAvatar(
        fallback: member.name,
        size: 40,
        radius: 20,
        url: member.avatarUrl,
      ),
      title: Text(
        member.name,
        style: const TextStyle(
          color: AppColors.onBackground,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        member.id,
        style: const TextStyle(color: AppColors.onSurfaceVariant, fontSize: 12),
      ),
      trailing: isCurrentUser
          ? null
          : IconButton(
              tooltip: _ignoredUsersLoadError != null
                  ? '无法加载忽略状态'
                  : ignored
                  ? '取消忽略'
                  : '忽略用户',
              icon: Icon(
                ignored ? Icons.person_add_alt_rounded : Icons.block_rounded,
                color: ignored ? AppColors.primary : AppColors.onSurfaceVariant,
              ),
              onPressed: _ignoredUsersLoadError == null
                  ? () => _setUserIgnored(member.id, !ignored)
                  : null,
            ),
    );
  }

  Widget _partialLoadErrorTile({
    required String label,
    required VoidCallback onRetry,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(
        Icons.error_outline_rounded,
        color: AppColors.onSurfaceVariant,
      ),
      title: Text(
        label,
        style: const TextStyle(color: AppColors.onSurfaceVariant),
      ),
      trailing: IconButton(
        tooltip: '重试',
        icon: const Icon(Icons.refresh_rounded),
        onPressed: onRetry,
      ),
    );
  }

  Widget _section({
    required String title,
    required Widget child,
    Widget? action,
  }) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadii.surface),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: AppColors.onBackground,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                ?action,
              ],
            ),
            child,
          ],
        ),
      ),
    );
  }

  Widget _actionTile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    final color = danger ? AppColors.error : AppColors.onBackground;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: danger ? AppColors.error : AppColors.primary),
      title: Text(label, style: TextStyle(color: color)),
      trailing: const Icon(
        Icons.chevron_right_rounded,
        color: AppColors.onSurfaceVariant,
      ),
      onTap: onTap,
    );
  }
}
