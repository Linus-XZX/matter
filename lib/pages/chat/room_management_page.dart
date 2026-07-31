import 'dart:async';
import 'dart:typed_data';

import 'package:clock/clock.dart';
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
import 'room_metadata_patch.dart';
import 'room_state_edit_tracker.dart';

class RoomManagementPage extends ConsumerStatefulWidget {
  final String roomId;
  final String roomName;
  final String? avatarUrl;
  final VoidCallback? onRoomClosed;
  final ValueChanged<RoomMetadataPatch>? onRoomDetailsChanged;

  const RoomManagementPage({
    super.key,
    required this.roomId,
    required this.roomName,
    this.avatarUrl,
    this.onRoomClosed,
    this.onRoomDetailsChanged,
  });

  @override
  ConsumerState<RoomManagementPage> createState() => _RoomManagementPageState();
}

class _RoomManagementPageState extends ConsumerState<RoomManagementPage> {
  final _nameController = TextEditingController();
  final _topicController = TextEditingController();
  final _imagePicker = ImagePicker();
  final _roomNameEdit = RoomStateEditTracker();
  final _roomAvatarEdit = RoomStateEditTracker();
  final _roomTopicEdit = RoomStateEditTracker();
  rust.RoomDetails? _details;
  Uint8List? _avatarPreviewBytes;
  List<rust.Contact> _members = const [];
  List<String> _ignoredUsers = const [];

  /// Knockers approved/rejected just now, hidden until the server echo
  /// removes them (or a short grace elapses) so entries don't flicker back.
  /// The grace bounds the hide: a genuine re-knock must become visible again.
  final Map<String, DateTime> _handledKnockUserIds = {};
  final Set<String> _pendingKnockUserIds = {};
  static const Duration _handledKnockGrace = Duration(seconds: 10);
  Timer? _handledKnockExpiryTimer;
  Object? _mutedLoadError;
  Object? _membersLoadError;
  Object? _ignoredUsersLoadError;
  bool _muted = false;
  bool _muteSaving = false;
  /// Generation counter for mute state: refresh/retry reads apply their
  /// value only if no toggle started after the read was issued, closing the
  /// window where a slow read lands after the toggle finished.
  int _muteEpoch = 0;
  bool _loading = true;
  int _ignoredUsersRevision = 0;
  bool _saving = false;
  bool _membersRefreshInFlight = false;
  bool _membersRefreshTrailing = false;
  /// Set once the full-page-error recovery has re-requested members, so the
  /// recovery check does not re-fire on every later sync cycle (e.g. for
  /// rooms whose member list is legitimately empty).
  bool _membersRecoveryAttempted = false;
  bool _roomStateRefreshInFlight = false;
  bool _roomStateRefreshTrailing = false;
  String? _error;
  late final StreamSubscription<rust.SyncEvent> _syncSubscription;
  late final ProviderSubscription<AsyncValue<Set<String>>>
  _ignoredUsersSubscription;

  @override
  void initState() {
    super.initState();
    _ignoredUsersSubscription = ref.listenManual(ignoredUserIdsProvider, (
      _,
      next,
    ) {
      if (!mounted) return;
      next.when(
        data: (ids) {
          setState(() {
            _ignoredUsersRevision++;
            _ignoredUsers = ids.toList()..sort();
            _ignoredUsersLoadError = null;
          });
        },
        error: (error, _) {
          setState(() {
            _ignoredUsersRevision++;
            _ignoredUsersLoadError = error;
          });
        },
        loading: () {},
      );
    });
    _load();
    _syncSubscription = rust.watchSyncEvents().listen((event) {
      if (!mounted) return;
      switch (event) {
        case rust.SyncEvent_SyncCompleted():
          unawaited(_refreshRoomState());
        case rust.SyncEvent_RoomMembersChanged(:final roomId)
            when roomId == widget.roomId:
          unawaited(_refreshMembers());
        case rust.SyncEvent_FullRefreshRequired():
          unawaited(_refreshMembers());
          unawaited(_refreshRoomState());
        case _:
          break;
      }
    });
  }

  @override
  void dispose() {
    _handledKnockExpiryTimer?.cancel();
    _syncSubscription.cancel();
    _ignoredUsersSubscription.close();
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
    if (!mounted) return;
    // Track whether a background member refresh was already in flight when
    // this load started: _load manages its own member fetch below and must
    // not clear the refresh loop's in-flight flag out from under it.
    final hadMembersRefreshInFlight = _membersRefreshInFlight;
    _membersRefreshInFlight = true;
    setState(() {
      _loading = true;
      _error = null;
      _mutedLoadError = null;
      _membersLoadError = null;
      _ignoredUsersLoadError = null;
    });
    try {
      final details = await rust.getRoomDetails(roomId: widget.roomId);
      final mutedFuture = _attempt(rust.isRoomMuted(roomId: widget.roomId));
      final membersFuture = _attempt(
        rust.getRoomMembers(roomId: widget.roomId),
      );
      final ignoredUsersRevision = _ignoredUsersRevision;
      final ignoredFuture = _attempt(ref.read(ignoredUserIdsProvider.future));
      final muted = await mutedFuture;
      final members = await membersFuture;
      final ignoredUsers = await ignoredFuture;
      if (!hadMembersRefreshInFlight) _membersRefreshInFlight = false;
      if (!mounted) return;
      setState(() {
        _details = details;
        _mutedLoadError = muted.error;
        _membersLoadError = members.error;
        if (_ignoredUsersRevision == ignoredUsersRevision) {
          _ignoredUsersLoadError = ignoredUsers.error;
          if (ignoredUsers.value case final value?) {
            _ignoredUsers = value.toList()..sort();
          }
        }
        if (muted.value case final value?) _muted = value;
        if (members.value case final value?) _members = value;
        _nameController.text = details.hasExplicitName ? details.name : '';
        _topicController.text = details.topic ?? '';
        _loading = false;
      });
      if (_membersRefreshTrailing) unawaited(_refreshMembers());
      if (_roomStateRefreshTrailing) unawaited(_refreshRoomState());
    } catch (error) {
      if (!hadMembersRefreshInFlight) _membersRefreshInFlight = false;
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
      if (_roomStateRefreshTrailing) unawaited(_refreshRoomState());
      if (_membersRefreshTrailing) unawaited(_refreshMembers());
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

  Future<void> _retryMuted() {
    final epoch = _muteEpoch;
    return _retryPartialLoad(
      load: () => rust.isRoomMuted(roomId: widget.roomId),
      updateValue: (value) {
        // A mute toggle issued after this retry's read started owns the
        // switch state, even if the toggle has already finished by the time
        // the read lands.
        if (_muteEpoch != epoch) return;
        _muted = value;
      },
      updateError: (error) {
        if (_muteEpoch != epoch) return;
        _mutedLoadError = error;
      },
    );
  }

  Future<void> _retryMembers() => _refreshMembers();

  Future<void> _refreshRoomState() async {
    if (_loading || _saving || _muteSaving || _roomStateRefreshInFlight) {
      _roomStateRefreshTrailing = true;
      return;
    }
    do {
      _roomStateRefreshTrailing = false;
      _roomStateRefreshInFlight = true;
      final muteEpoch = _muteEpoch;
      final detailsFuture = _attempt(
        rust.getRoomDetails(roomId: widget.roomId),
      );
      final mutedFuture = _attempt(rust.isRoomMuted(roomId: widget.roomId));
      final details = await detailsFuture;
      final muted = await mutedFuture;
      _roomStateRefreshInFlight = false;
      if (!mounted) return;
      setState(() {
        // A mute toggle issued after this read started owns the switch state
        // — including its error display: a stale read failure must not
        // disable a switch the user just toggled successfully.
        if (_muteEpoch == muteEpoch) {
          _mutedLoadError = muted.error;
          if (muted.value != null) {
            _muted = muted.value!;
          }
        }
        if (details.value case final value?) {
          _mergeRemoteDetails(value);
          // A background refresh recovering after an initial load failure
          // must leave the full-page error state, or the page would hold
          // valid data while still rendering the error screen.
          _error = null;
        } else if (details.error != null) {
          debugPrint('refresh room details failed: ${details.error}');
        }
      });
      if (!_membersRecoveryAttempted &&
          _members.isEmpty &&
          _membersLoadError == null &&
          mounted) {
        // The full-page error path never loaded members (their future was
        // discarded by the failed initial _load). Restore them once, or the
        // recovered page would silently show "成员 0" with no retry entry.
        _membersRecoveryAttempted = true;
        unawaited(_refreshMembers());
      }
    } while (_roomStateRefreshTrailing && mounted);
  }

  void _mergeRemoteDetails(rust.RoomDetails remote) {
    final current = _details;
    if (current == null) {
      _details = remote;
      _nameController.text = remote.hasExplicitName ? remote.name : '';
      _topicController.text = remote.topic ?? '';
      _avatarPreviewBytes = null;
      return;
    }

    final currentNameText = current.hasExplicitName ? current.name : '';
    final currentTopicText = current.topic ?? '';
    final nameEdited = _nameController.text != currentNameText;
    final topicEdited = _topicController.text != currentTopicText;
    final acceptName =
        !nameEdited && _roomNameEdit.shouldAccept(remote.nameEventId);
    final acceptTopic =
        !topicEdited && _roomTopicEdit.shouldAccept(remote.topicEventId);
    final acceptAvatar = _roomAvatarEdit.shouldAccept(remote.avatarEventId);
    final avatarChanged =
        acceptAvatar &&
        (current.avatarUrl != remote.avatarUrl ||
            current.avatarEventId != remote.avatarEventId);

    if (acceptName) {
      _nameController.text = remote.hasExplicitName ? remote.name : '';
    }
    if (acceptTopic) {
      _topicController.text = remote.topic ?? '';
    }
    if (acceptAvatar && (_avatarPreviewBytes != null || avatarChanged)) {
      _avatarPreviewBytes = null;
    }

    _details = rust.RoomDetails(
      id: remote.id,
      name: acceptName ? remote.name : current.name,
      hasExplicitName: acceptName
          ? remote.hasExplicitName
          : current.hasExplicitName,
      avatarUrl: acceptAvatar ? remote.avatarUrl : current.avatarUrl,
      nameEventId: acceptName ? remote.nameEventId : current.nameEventId,
      avatarEventId: acceptAvatar
          ? remote.avatarEventId
          : current.avatarEventId,
      topicEventId: acceptTopic ? remote.topicEventId : current.topicEventId,
      topic: acceptTopic ? remote.topic : current.topic,
    );
  }

  Future<void> _refreshMembers() async {
    if (_membersRefreshInFlight) {
      _membersRefreshTrailing = true;
      return;
    }
    do {
      _membersRefreshTrailing = false;
      _membersRefreshInFlight = true;
      final result = await _attempt(rust.getRoomMembers(roomId: widget.roomId));
      _membersRefreshInFlight = false;
      if (!mounted) return;
      setState(() {
        _membersLoadError = result.error;
        if (result.value case final value?) _members = value;
      });
    } while (_membersRefreshTrailing && mounted);
  }

  Future<void> _retryKnocks() async {
    ref.invalidate(roomKnockRequestsProvider(widget.roomId));
    try {
      await ref.read(roomKnockRequestsProvider(widget.roomId).future);
    } catch (_) {
      // The provider exposes the retry error in the section.
    }
  }

  Future<void> _retryIgnoredUsers() async {
    ref.invalidate(ignoredUserIdsProvider);
    try {
      await ref.read(ignoredUserIdsProvider.future);
    } catch (_) {
      // The provider listener exposes the retry error in the section.
    }
  }

  void _invalidateRoom() {
    if (!mounted) return;
    ref.invalidate(chatRoomsProvider);
    ref.invalidate(ungroupedRoomsProvider);
    ref.invalidate(spaceChildrenProvider);
    ref.invalidate(searchRoomsProvider);
    ref.invalidate(roomMembersProvider(widget.roomId));
    ref.invalidate(roomKnockRequestsProvider(widget.roomId));
  }

  void _closeCurrentRoom() {
    final navigator = Navigator.of(context);
    // An async room action may complete after the user already popped this
    // page (e.g. back button while the action was in flight). Popping the
    // chat underneath then would kick the user out of the conversation they
    // intended to stay in, so only close when this page is still the active
    // route. During a pop animation the route is already removed from the
    // navigator history, which `isCurrent` reflects immediately.
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return;
    final handledByParent = widget.onRoomClosed != null;
    widget.onRoomClosed?.call();
    if (navigator.canPop()) navigator.pop();
    if (!handledByParent && navigator.canPop()) navigator.pop();
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
    final topic = _topicController.text.trim().isEmpty
        ? null
        : _topicController.text.trim();
    final updateTopic = topic != details.topic;
    setState(() => _saving = true);
    try {
      final result = await rust.updateRoomDetails(
        roomId: widget.roomId,
        name: name,
        updateName: updateName,
        updateTopic: updateTopic,
        topic: updateTopic ? topic : null,
      );
      _invalidateRoom();
      if (!mounted) return;
      final currentDetails = _details;
      if (currentDetails == null) return;
      final nameUpdated = updateName && result.nameError == null;
      if (nameUpdated) {
        _roomNameEdit.record(
          currentEventId: currentDetails.nameEventId,
          nextEventId: result.nameEventId,
        );
      }
      if (updateTopic && result.topicError == null) {
        _roomTopicEdit.record(
          currentEventId: currentDetails.topicEventId,
          nextEventId: result.topicEventId,
        );
      }
      final updatedDetails = rust.RoomDetails(
        id: currentDetails.id,
        name: nameUpdated ? name : currentDetails.name,
        hasExplicitName: currentDetails.hasExplicitName || nameUpdated,
        avatarUrl: currentDetails.avatarUrl,
        nameEventId: nameUpdated
            ? result.nameEventId
            : currentDetails.nameEventId,
        avatarEventId: currentDetails.avatarEventId,
        topicEventId: updateTopic && result.topicError == null
            ? result.topicEventId
            : currentDetails.topicEventId,
        topic: updateTopic && result.topicError == null
            ? topic
            : currentDetails.topic,
      );
      final detailsChanged = updatedDetails != currentDetails;
      if (detailsChanged) {
        setState(() => _details = updatedDetails);
      }
      if (nameUpdated) {
        widget.onRoomDetailsChanged?.call(
          RoomNamePatch(
            roomId: currentDetails.id,
            name: name,
            nameEventId: result.nameEventId,
          ),
        );
      }
      final failures = [
        if (result.nameError case final error?) '房间名称更新失败: $error',
        if (result.topicError case final error?) '主题更新失败: $error',
      ];
      if (failures.isEmpty) {
        _showSnackBar('房间信息已更新');
      } else {
        final prefix = detailsChanged ? '部分更新成功：' : '';
        _showSnackBar('$prefix${failures.join('；')}');
      }
    } catch (error) {
      if (mounted) _showSnackBar('更新失败: $error');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
        if (_roomStateRefreshTrailing) unawaited(_refreshRoomState());
      }
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
      final avatarUpdate = await rust.uploadRoomAvatar(
        roomId: widget.roomId,
        contentType: 'image/jpeg',
        data: bytes,
      );
      _invalidateRoom();
      if (!mounted) return;
      final details = _details!;
      _roomAvatarEdit.record(
        currentEventId: details.avatarEventId,
        nextEventId: avatarUpdate.eventId,
      );
      final updatedDetails = rust.RoomDetails(
        id: details.id,
        name: details.name,
        hasExplicitName: details.hasExplicitName,
        avatarUrl: avatarUpdate.avatarUrl,
        nameEventId: details.nameEventId,
        avatarEventId: avatarUpdate.eventId,
        topicEventId: details.topicEventId,
        topic: details.topic,
      );
      setState(() {
        _details = updatedDetails;
        _avatarPreviewBytes = bytes;
      });
      widget.onRoomDetailsChanged?.call(
        RoomAvatarPatch(
          roomId: details.id,
          avatarUrl: avatarUpdate.avatarUrl,
          avatarEventId: avatarUpdate.eventId,
        ),
      );
      _showSnackBar('房间头像已更新');
    } catch (error) {
      if (mounted) _showSnackBar('头像更新失败: $error');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
        if (_roomStateRefreshTrailing) unawaited(_refreshRoomState());
      }
    }
  }

  Future<void> _setMuted(bool muted) async {
    if (_muteSaving) return;
    _muteEpoch++;
    setState(() {
      _muteSaving = true;
      _muted = muted;
    });
    try {
      await rust.setRoomMuted(roomId: widget.roomId, muted: muted);
      if (!mounted) return;
      // A successful toggle also clears any stale error state from reads
      // that raced it.
      setState(() => _mutedLoadError = null);
      _invalidateRoom();
      _showSnackBar(muted ? '已开启免打扰' : '已关闭免打扰');
    } catch (error) {
      if (mounted) {
        setState(() => _muted = !muted);
        _showSnackBar('通知设置更新失败: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _muteSaving = false);
        if (_roomStateRefreshTrailing) unawaited(_refreshRoomState());
      }
    }
  }

  void _showInviteDialog() {
    final controller = TextEditingController();
    var inviting = false;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => PopScope(
          // The request runs with the dialog still open; dismissing it
          // mid-flight (barrier tap, system back) must not be possible —
          // the feedback below is guarded on the dialog still being up.
          canPop: !inviting,
          child: AlertDialog(
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
                onPressed: inviting
                    ? null
                    : () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: inviting
                    ? null
                    : () async {
                        // Entry guard (not only the disabled button): the
                        // rebuild lags a frame, so a second tap on the old
                        // widget could otherwise issue a duplicate invite.
                        if (inviting) return;
                        final userId = controller.text.trim();
                        if (userId.isEmpty) return;
                        setDialogState(() => inviting = true);
                        try {
                          await rust.inviteUserToRoom(
                            roomId: widget.roomId,
                            userId: userId,
                          );
                          if (!mounted) return;
                          // Room invalidation and the feedback must not
                          // depend on the dialog still being up: a dismissal
                          // race would otherwise swallow the result.
                          _invalidateRoom();
                          _showSnackBar('邀请已发送');
                          if (dialogContext.mounted) {
                            Navigator.of(dialogContext).pop();
                          }
                        } catch (error) {
                          if (!mounted) return;
                          if (dialogContext.mounted) {
                            setDialogState(() => inviting = false);
                          }
                          _showSnackBar('邀请失败: $error');
                        }
                      },
                child: const Text('邀请'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _setUserIgnored(String userId, bool ignored) async {
    // Captured before the await: the write-through must run even if this
    // page is popped while the server request is in flight.
    final namespace = ref.read(activeUserIdProvider) ?? '';
    try {
      final updated = await rust.setUserIgnored(
        accountUserId: namespace,
        userId: userId,
        ignored: ignored,
      );
      // The server write succeeded: write the returned full list through to
      // the local snapshot so open timelines hide/show the sender's messages
      // now, without waiting for a background refresh that may fail offline.
      // Persisting the complete list (not a delta) also keeps other ignored
      // users when no local snapshot exists yet. The write-through itself
      // revalidates ignoredUserIdsProvider app-wide, so this stays correct
      // even when the page is popped before the request completes.
      await persistIgnoredUserList(namespace, updated.toSet());
      if (!mounted) return;
      setState(() {
        _ignoredUsers = updated.toList()..sort();
      });
      _showSnackBar(ignored ? '已忽略 $userId' : '已取消忽略 $userId');
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
    if (_pendingKnockUserIds.contains(request.userId)) return;
    setState(() => _pendingKnockUserIds.add(request.userId));
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
      if (!mounted) return;
      setState(() => _handledKnockUserIds[request.userId] = clock.now());
      _scheduleHandledKnockExpiry();
      _invalidateRoom();
      if (approve) {
        await _retryMembers();
        if (!mounted) return;
      }
      _showSnackBar(approve ? '已批准加入请求' : '已拒绝加入请求');
    } catch (error) {
      if (mounted) _showSnackBar('操作失败: $error');
    } finally {
      if (mounted) {
        setState(() => _pendingKnockUserIds.remove(request.userId));
      }
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
                _closeCurrentRoom();
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

  bool _isKnockHidden(String userId) {
    final handledAt = _handledKnockUserIds[userId];
    return handledAt != null &&
        clock.now().difference(handledAt) < _handledKnockGrace;
  }

  void _scheduleHandledKnockExpiry() {
    _handledKnockExpiryTimer?.cancel();
    if (_handledKnockUserIds.isEmpty) return;
    final now = clock.now();
    final nextExpiry = _handledKnockUserIds.values
        .map((handledAt) => handledAt.add(_handledKnockGrace))
        .reduce((earlier, later) => earlier.isBefore(later) ? earlier : later);
    final delay = nextExpiry.difference(now);
    _handledKnockExpiryTimer = Timer(
      delay.isNegative ? Duration.zero : delay,
      () {
        if (!mounted) return;
        setState(() {
          _handledKnockUserIds.removeWhere(
            (_, handledAt) =>
                !handledAt.add(_handledKnockGrace).isAfter(nextExpiry),
          );
        });
        _scheduleHandledKnockExpiry();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Keep the shared sync handler alive so ignoredUserIdsProvider receives
    // account-data and lag-compensation invalidations even when this page is
    // tested or presented outside the usual app shell.
    ref.watch(syncStreamProvider);
    final details = _details;
    final knockRequestsAsync = ref.watch(
      roomKnockRequestsProvider(widget.roomId),
    );
    ref.listen(roomKnockRequestsProvider(widget.roomId), (_, next) {
      next.whenData((requests) {
        final activeUserIds = requests.map((request) => request.userId).toSet();
        final previousCount = _handledKnockUserIds.length;
        _handledKnockUserIds.removeWhere(
          (userId, _) =>
              !activeUserIds.contains(userId) || !_isKnockHidden(userId),
        );
        if (mounted && previousCount != _handledKnockUserIds.length) {
          setState(() {});
          _scheduleHandledKnockExpiry();
        }
      });
    });
    final knockRequests =
        // `value` keeps the previous list while a refresh is in flight
        // (`asData` is null during loading), so the section does not blink
        // out of existence on every sync cycle.
        (knockRequestsAsync.value ?? const <rust.KnockRequest>[])
            .where((request) => !_isKnockHidden(request.userId))
            .toList();
    final knocksLoadError = knockRequestsAsync.hasError
        ? knockRequestsAsync.error
        : null;
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
                            if (_avatarPreviewBytes case final bytes?)
                              ClipRRect(
                                borderRadius: BorderRadius.circular(
                                  AppRadii.content,
                                ),
                                child: Image.memory(
                                  bytes,
                                  width: 76,
                                  height: 76,
                                  fit: BoxFit.cover,
                                ),
                              )
                            else
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
                if (knocksLoadError != null || knockRequests.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _section(
                    title: knocksLoadError == null
                        ? '加入请求 ${knockRequests.length}'
                        : '加入请求',
                    child: knocksLoadError != null
                        ? _partialLoadErrorTile(
                            label: '无法加载加入请求',
                            onRetry: _retryKnocks,
                          )
                        : Column(
                            children: [
                              for (final request in knockRequests)
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
                                        onPressed:
                                            _pendingKnockUserIds.contains(
                                              request.userId,
                                            )
                                            ? null
                                            : () => _runKnockAction(
                                                request,
                                                true,
                                              ),
                                      ),
                                      IconButton(
                                        tooltip: '拒绝',
                                        icon: const Icon(
                                          Icons.close_rounded,
                                          color: AppColors.error,
                                        ),
                                        onPressed:
                                            _pendingKnockUserIds.contains(
                                              request.userId,
                                            )
                                            ? null
                                            : () => _runKnockAction(
                                                request,
                                                false,
                                              ),
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
                        onChanged: _mutedLoadError == null && !_muteSaving
                            ? _setMuted
                            : null,
                        secondary: _mutedLoadError == null
                            ? null
                            : IconButton(
                                tooltip: '重试',
                                icon: const Icon(Icons.refresh_rounded),
                                onPressed: _muteSaving
                                    ? null
                                    : _retryMuted,
                              ),
                      ),
                      _actionTile(
                        icon: Icons.push_pin_rounded,
                        label: '置顶消息',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                PinnedMessagesPage(roomId: widget.roomId),
                          ),
                        ),
                      ),
                      _actionTile(
                        icon: Icons.done_all_rounded,
                        label: '标记为已读',
                        onTap: () async {
                          final suppression = roomAutoReadSuppressedProvider(
                            widget.roomId,
                          );
                          final suppressionNotifier = ref.read(
                            suppression.notifier,
                          );
                          final previousSuppression = suppressionNotifier.value;
                          final suppressionToken = setRoomAutoReadSuppressed(
                            ref,
                            widget.roomId,
                            suppressed: false,
                          );
                          try {
                            await rust.markRoomAsRead(roomId: widget.roomId);
                            if (!mounted || !suppressionToken.isCurrent) {
                              return;
                            }
                            setRoomUnreadOverrideById(
                              ref,
                              widget.roomId,
                              unread: false,
                            );
                            _invalidateRoom();
                            _showSnackBar('已标记为已读');
                          } catch (error) {
                            if (!suppressionToken.isCurrent) return;
                            suppressionNotifier.value = previousSuppression;
                            if (!mounted) return;
                            _showSnackBar('操作失败: $error');
                          }
                        },
                      ),
                      _actionTile(
                        icon: Icons.mark_unread_chat_alt_rounded,
                        label: '标记为未读',
                        onTap: () async {
                          final suppression = roomAutoReadSuppressedProvider(
                            widget.roomId,
                          );
                          final suppressionNotifier = ref.read(
                            suppression.notifier,
                          );
                          final unreadOverrideNotifier = ref.read(
                            roomUnreadOverrideProvider(widget.roomId).notifier,
                          );
                          final previousSuppression = suppressionNotifier.value;
                          final previousUnreadOverride =
                              unreadOverrideNotifier.value;
                          final suppressionToken = setRoomAutoReadSuppressed(
                            ref,
                            widget.roomId,
                            suppressed: true,
                          );
                          setRoomUnreadOverrideById(
                            ref,
                            widget.roomId,
                            unread: true,
                          );
                          try {
                            await rust.markRoomUnread(roomId: widget.roomId);
                            if (!mounted || !suppressionToken.isCurrent) {
                              return;
                            }
                            _invalidateRoom();
                            _showSnackBar('已标记为未读');
                            _closeCurrentRoom();
                          } catch (error) {
                            if (!suppressionToken.isCurrent) return;
                            suppressionNotifier.value = previousSuppression;
                            unreadOverrideNotifier.value =
                                previousUnreadOverride;
                            if (!mounted) return;
                            _showSnackBar('操作失败: $error');
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
