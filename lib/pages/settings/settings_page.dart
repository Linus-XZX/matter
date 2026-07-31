import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/app_update/app_update_service.dart';
import '../../features/app_update/update_dialog.dart';
import '../../features/cache/image_cache_control.dart';
import '../../features/diagnostics/diagnostic_exporter.dart';
import '../../providers/auth_provider.dart';
import '../../providers/authenticated_media_cache.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;

import '../../theme/app_theme.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/app_card.dart';
import 'encryption_page.dart';
import 'log_viewer_page.dart';
import 'profile_edit_page.dart';

final accountSwitchControllerProvider = Provider(AccountSwitchController.new);
final accountSessionRemoverProvider = Provider<Future<void> Function(String)>(
  (_) => removeSession,
);

class AccountSwitchController {
  final Ref _ref;
  Future<void> _operationTail = Future.value();

  AccountSwitchController(this._ref);

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _operationTail.then((_) => operation());
    _operationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  String? _appendCleanupWarning(String? current, Object error) {
    final next = '本地会话清理失败: $error';
    return current == null ? next : '$current；$next';
  }

  Future<T> _runWithPersistedRemovalIntent<T>(
    String userId,
    Future<T> Function() removeFromRust,
  ) async {
    await markSessionRemoved(userId);
    try {
      return await removeFromRust();
    } catch (error, stackTrace) {
      try {
        await unmarkSessionRemoved(userId);
      } catch (rollbackError) {
        throw StateError('账号删除失败：$error；本地删除状态回滚失败：$rollbackError');
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<String?> _commitLocalAccountRemoval(
    String userId,
    String? cleanupWarning,
  ) async {
    var warning = cleanupWarning;
    try {
      await _ref.read(accountSessionRemoverProvider)(userId);
    } catch (error) {
      warning = _appendCleanupWarning(warning, error);
    }

    final current = _ref
        .read(sessionsProvider)
        .where((session) => session.userId != userId)
        .toList();
    try {
      _ref.read(sessionsProvider.notifier).value = (await loadAllSessions())
          .where((session) => session.userId != userId)
          .toList();
    } catch (error) {
      _ref.read(sessionsProvider.notifier).value = current;
      warning = _appendCleanupWarning(warning, error);
    }
    return warning;
  }

  Future<void> switchTo(String userId) => _serialize(() => _switchTo(userId));

  Future<String?> removeAccount(String userId) =>
      _serialize(() => _removeAccount(userId));

  Future<void> _switchTo(String userId) async {
    final activeId = _ref.read(activeUserIdProvider);
    if (userId == activeId) return;

    final sessions = await loadAllSessions();
    rust.StoredSession? sessionFor(String id) => sessions
        .cast<rust.StoredSession?>()
        .firstWhere((session) => session?.userId == id, orElse: () => null);

    final targetSession = sessionFor(userId);
    if (targetSession == null) {
      throw StateError('找不到已保存的账号会话');
    }
    final targetDisplayName = await loadDisplayName(userId);
    final previousSession = activeId == null ? null : sessionFor(activeId);
    if (activeId != null && previousSession == null) {
      throw StateError('找不到当前账号的已保存会话');
    }
    final previousDisplayName = activeId == null
        ? null
        : await loadDisplayName(activeId);

    var switchedClient = false;
    if (activeId != null) {
      // Invalidate outgoing async work before the process-wide Rust client
      // changes accounts.
      resetIgnoredListAccountState(activeId);
    }
    _ref.read(sessionReadyProvider.notifier).value = false;
    var restoreSessionGate = false;
    try {
      final success = await rust.switchAccount(userId: userId);
      if (!success) throw StateError('账号切换未生效');
      switchedClient = true;

      await applyActiveSessionStateFromRef(
        _ref,
        userId: userId,
        displayName: targetDisplayName,
        homeserver: targetSession.homeserverUrl,
        persistActiveUser: true,
        refreshStoredSessions: true,
      );
      await bootstrapActiveSessionSyncFromRef(
        _ref,
        attemptLabel: 'syncOnce after switch attempt',
        startSyncLabel: 'startSync after switch failed',
        requireSyncLoop: true,
      );
      restoreSessionGate = true;
    } catch (error, stackTrace) {
      if (switchedClient &&
          activeId != null &&
          previousSession != null &&
          previousDisplayName != null) {
        try {
          final reverted = await rust.switchAccount(userId: activeId);
          if (!reverted) throw StateError('原账号回滚未生效');
          await applyActiveSessionStateFromRef(
            _ref,
            userId: activeId,
            displayName: previousDisplayName,
            homeserver: previousSession.homeserverUrl,
            persistActiveUser: true,
            refreshStoredSessions: true,
          );
          await bootstrapActiveSessionSyncFromRef(
            _ref,
            attemptLabel: 'syncOnce after switch rollback attempt',
            startSyncLabel: 'startSync after switch rollback failed',
            requireSyncLoop: true,
          );
          restoreSessionGate = true;
        } catch (rollbackError) {
          throw StateError('账号切换失败：$error；回滚失败：$rollbackError');
        }
      } else {
        restoreSessionGate = true;
      }
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      _ref.read(sessionReadyProvider.notifier).value = restoreSessionGate;
    }
  }

  Future<String?> _removeAccount(String userId) async {
    final activeId = _ref.read(activeUserIdProvider);
    final isCurrentAccount = userId == activeId;
    final remaining = isCurrentAccount
        ? (await loadAllSessions())
              .where((session) => session.userId != userId)
              .toList()
        : const <rust.StoredSession>[];

    if (remaining.isNotEmpty) {
      // This whole switch-and-remove sequence stays inside the same queue, so
      // no later account action can reactivate the account being deleted.
      await _switchTo(remaining.first.userId);
      final result = await _runWithPersistedRemovalIntent(
        userId,
        () => rust.removeAccount(userId: userId),
      );
      return _commitLocalAccountRemoval(userId, result.cleanupError);
    } else if (isCurrentAccount) {
      _ref.read(sessionReadyProvider.notifier).value = false;
      late final rust.AccountRemovalResult result;
      try {
        result = await _runWithPersistedRemovalIntent(userId, rust.logout);
      } catch (error, stackTrace) {
        try {
          await bootstrapActiveSessionSyncFromRef(
            _ref,
            attemptLabel: 'syncOnce after logout failure attempt',
            startSyncLabel: 'startSync after logout failure failed',
            requireSyncLoop: true,
          );
          _ref.read(sessionReadyProvider.notifier).value = true;
        } catch (recoveryError) {
          clearActiveSessionStateFromRef(_ref, markSessionReady: true);
          throw StateError('退出失败：$error；恢复同步失败：$recoveryError');
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
      final warning = await _commitLocalAccountRemoval(
        userId,
        result.cleanupError,
      );
      try {
        return warning;
      } finally {
        _ref.read(sessionsProvider.notifier).value =
            const <rust.StoredSession>[];
        clearActiveSessionStateFromRef(_ref, markSessionReady: true);
      }
    } else {
      final result = await _runWithPersistedRemovalIntent(
        userId,
        () => rust.removeAccount(userId: userId),
      );
      return _commitLocalAccountRemoval(userId, result.cleanupError);
    }
  }
}

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  List<rust.AccountInfo> _accounts = [];
  Object? _accountsLoadError;
  String _versionLabel = '读取中…';
  String _cacheSizeLabel = '计算中…';
  bool _checkingForUpdate = false;
  bool _exportingDiagnostics = false;
  bool _exportingLogs = false;
  bool _clearingCache = false;

  @override
  void initState() {
    super.initState();
    _loadAccounts();
    _loadAppVersion();
    if (!kIsWeb) _loadCacheSize();
    unawaited(refreshCurrentUserProfile(ref));
  }

  Future<void> _loadAppVersion() async {
    try {
      final version = await appUpdateService.getCurrentVersion();
      if (mounted) setState(() => _versionLabel = version.displayName);
    } catch (error) {
      debugPrint('Failed to load app version: $error');
      if (mounted) setState(() => _versionLabel = '版本信息不可用');
    }
  }

  Future<void> _checkForUpdate() async {
    if (_checkingForUpdate) return;
    setState(() => _checkingForUpdate = true);
    try {
      final result = await appUpdateService.checkForUpdate(force: true);
      if (!mounted) return;
      switch (result.status) {
        case UpdateCheckStatus.available:
          await showAvailableUpdateDialog(
            context,
            service: appUpdateService,
            current: result.current,
            update: result.update!,
          );
        case UpdateCheckStatus.upToDate:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${result.current.displayName} 已是最新版本'),
              duration: const Duration(milliseconds: 1200),
            ),
          );
        case UpdateCheckStatus.unsupported:
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('当前平台暂不支持应用内更新')));
        case UpdateCheckStatus.skipped:
          break;
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('检查更新失败：$error')));
    } finally {
      if (mounted) setState(() => _checkingForUpdate = false);
    }
  }

  Future<void> _exportDiagnostics() async {
    if (_exportingDiagnostics) return;
    setState(() => _exportingDiagnostics = true);
    try {
      final saved = await const DiagnosticExporter().export();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(saved ? '诊断报告已导出' : '已取消导出')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出诊断报告失败：$error')));
    } finally {
      if (mounted) setState(() => _exportingDiagnostics = false);
    }
  }

  Future<void> _exportLogs() async {
    if (_exportingLogs) return;
    setState(() => _exportingLogs = true);
    try {
      final saved = await const DiagnosticExporter().exportLogsZip();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(saved ? '日志包已导出' : '已取消导出')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出日志包失败：$error')));
    } finally {
      if (mounted) setState(() => _exportingLogs = false);
    }
  }

  Future<void> _loadCacheSize() async {
    try {
      final bytes = await imageCacheSizeBytes();
      if (mounted) setState(() => _cacheSizeLabel = _formatCacheSize(bytes));
    } catch (error) {
      debugPrint('Failed to measure cache size: $error');
      if (mounted) setState(() => _cacheSizeLabel = '大小未知');
    }
  }

  Future<void> _clearCache() async {
    if (_clearingCache) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          '清理缓存',
          style: TextStyle(color: AppColors.onBackground),
        ),
        content: const Text(
          '将删除已下载的图片与媒体缓存，下次查看时会重新加载。确定继续吗？',
          style: TextStyle(color: AppColors.onSurfaceVariant),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _clearingCache = true);
    try {
      imageCache.clear();
      await resetAuthenticatedMediaCacheManagers();
      await clearImageCacheFiles();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('缓存已清理'),
          duration: Duration(milliseconds: 1200),
        ),
      );
      await _loadCacheSize();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('清理缓存失败：$error')));
    } finally {
      if (mounted) setState(() => _clearingCache = false);
    }
  }

  Future<void> _loadAccounts() async {
    try {
      final accounts = await rust.listAccounts();
      if (mounted) {
        setState(() {
          _accounts = accounts;
          _accountsLoadError = null;
        });
      }
    } catch (e) {
      debugPrint('Failed to load accounts: $e');
      if (mounted) {
        setState(() {
          _accounts = const [];
          _accountsLoadError = e;
        });
      }
    }
  }

  Future<void> _switchAccount(String userId) async {
    final controller = ref.read(accountSwitchControllerProvider);
    try {
      await controller.switchTo(userId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('切换账号失败: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _removeAccount(String userId) async {
    final activeId = ref.read(activeUserIdProvider);
    final isCurrentAccount = userId == activeId;
    final accountController = ref.read(accountSwitchControllerProvider);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(
          isCurrentAccount ? '退出登录' : '移除账号',
          style: const TextStyle(color: AppColors.onBackground),
        ),
        content: Text(
          isCurrentAccount ? '确定要退出当前账号吗？' : '确定要移除这个账号吗？',
          style: const TextStyle(color: AppColors.onSurfaceVariant),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('确定'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final cleanupError = await accountController.removeAccount(userId);
      await _loadAccounts();
      if (cleanupError != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('账号已移除，但本地缓存清理失败: $cleanupError'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      debugPrint('Failed to remove account: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('操作失败: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = ref.watch(currentUserProvider);
    final activeUserId = ref.watch(activeUserIdProvider);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          const SliverAppBar(
            floating: true,
            pinned: true,
            title: Text(
              '设置',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: AppColors.onBackground,
                letterSpacing: -0.5,
              ),
            ),
            backgroundColor: AppColors.background,
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: 96,
              ),
              child: Column(
                children: [
                  // Profile card
                  AppCard(
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const ProfileEditPage(),
                        ),
                      );
                    },
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        AppAvatar(
                          fallback: currentUser?.displayName ?? '我',
                          size: 60,
                          url: currentUser?.avatarUrl,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                currentUser?.displayName ?? '未登录',
                                style: const TextStyle(
                                  color: AppColors.onBackground,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                currentUser != null
                                    ? currentUser.id
                                    : '点击登录你的 Matrix 账号',
                                style: const TextStyle(
                                  color: AppColors.onSurfaceVariant,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  // ── Account switcher ────────────────────────────────
                  if (_accountsLoadError != null) ...[
                    const SizedBox(height: 20),
                    _buildGroup(
                      title: '账号',
                      items: [
                        _SettingItem(
                          icon: Icons.error_outline_rounded,
                          iconColor: AppColors.error,
                          title: '账号列表加载失败',
                          subtitle: '$_accountsLoadError',
                          onTap: _loadAccounts,
                        ),
                      ],
                    ),
                  ] else if (_accounts.length > 1) ...[
                    const SizedBox(height: 20),
                    _buildGroup(
                      title: '账号切换',
                      items: _accounts.map((account) {
                        final isActive = account.userId == activeUserId;
                        return _SettingItem(
                          icon: Icons.person_outline_rounded,
                          iconColor: isActive
                              ? AppColors.primary
                              : AppColors.onSurfaceVariant,
                          title: _formatUserId(account.userId),
                          subtitle: account.homeserverUrl.replaceAll(
                            RegExp(r'https?://'),
                            '',
                          ),
                          trailing: isActive
                              ? const Icon(
                                  Icons.check_circle_rounded,
                                  color: AppColors.primary,
                                  size: 20,
                                )
                              : null,
                          onTap: isActive
                              ? null
                              : () => _switchAccount(account.userId),
                        );
                      }).toList(),
                    ),
                  ],

                  const SizedBox(height: 20),
                  // Settings groups
                  _buildGroup(
                    title: '通用',
                    items: [
                      _SettingItem(
                        icon: Icons.dark_mode_rounded,
                        iconColor: AppColors.secondary,
                        title: '主题',
                        subtitle: '当前固定为深色',
                      ),
                      _SettingItem(
                        icon: Icons.notifications_rounded,
                        iconColor: AppColors.warning,
                        title: '通知',
                        subtitle: '免打扰请在房间管理中设置',
                      ),
                      _SettingItem(
                        icon: Icons.language_rounded,
                        iconColor: AppColors.success,
                        title: '语言',
                        subtitle: '当前固定为简体中文',
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _buildGroup(
                    title: 'Matrix',
                    items: [
                      _SettingItem(
                        icon: Icons.account_tree_rounded,
                        iconColor: AppColors.primary,
                        title: 'Homeserver',
                        subtitle:
                            currentUser?.homeserver.replaceAll(
                              RegExp(r'https?://'),
                              '',
                            ) ??
                            'matrix.org',
                      ),
                      _SettingItem(
                        icon: Icons.sync_rounded,
                        iconColor: AppColors.primaryVariant,
                        title: '同步设置',
                        subtitle: '自动管理，无手动配置项',
                      ),
                      _SettingItem(
                        icon: Icons.security_rounded,
                        iconColor: AppColors.success,
                        title: '加密',
                        subtitle: '设备验证与加密恢复',
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const EncryptionPage(),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  // On web there is no app-managed disk cache to clear; the
                  // browser owns the HTTP cache.
                  if (!kIsWeb) ...[
                    const SizedBox(height: 20),
                    _buildGroup(
                      title: '存储',
                      items: [
                        _SettingItem(
                          icon: Icons.cleaning_services_rounded,
                          iconColor: AppColors.secondary,
                          title: '清理缓存',
                          subtitle: '图片与媒体缓存 · $_cacheSizeLabel',
                          trailing: _clearingCache
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : null,
                          onTap: _clearingCache ? null : _clearCache,
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 20),
                  _buildGroup(
                    title: '关于',
                    items: [
                      _SettingItem(
                        icon: Icons.info_rounded,
                        iconColor: AppColors.onSurfaceVariant,
                        title: '当前版本',
                        subtitle: _versionLabel,
                        onTap:
                            appUpdateService.isSupported && !_checkingForUpdate
                            ? _checkForUpdate
                            : null,
                        trailing: _checkingForUpdate
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : null,
                      ),
                      _SettingItem(
                        icon: Icons.code_rounded,
                        iconColor: AppColors.onSurfaceVariant,
                        title: '开源许可',
                        subtitle: '',
                        onTap: () {
                          showLicensePage(context: context);
                        },
                      ),
                      _SettingItem(
                        icon: Icons.terminal_rounded,
                        iconColor: AppColors.warning,
                        title: '查看日志',
                        subtitle: '调试连接、同步问题',
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const LogViewerPage(),
                            ),
                          );
                        },
                      ),
                      _SettingItem(
                        icon: Icons.file_download_outlined,
                        iconColor: AppColors.primary,
                        title: '导出诊断报告',
                        subtitle: '包含日志、设备及版本信息',
                        trailing: _exportingDiagnostics
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : null,
                        onTap: _exportingDiagnostics
                            ? null
                            : _exportDiagnostics,
                      ),
                      _SettingItem(
                        icon: Icons.folder_zip_outlined,
                        iconColor: AppColors.primaryVariant,
                        title: '导出日志包',
                        subtitle: '完整日志 zip，已脱敏',
                        trailing: _exportingLogs
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : null,
                        onTap: _exportingLogs ? null : _exportLogs,
                      ),
                    ],
                  ),
                  if (currentUser != null) ...[
                    const SizedBox(height: 20),
                    // Remove other accounts (not current)
                    ..._accounts
                        .where((a) => a.userId != activeUserId)
                        .map(
                          (account) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: AppCard(
                              color: AppColors.onSurfaceVariant.withValues(
                                alpha: 0.06,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 10,
                              ),
                              onTap: () => _removeAccount(account.userId),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.remove_circle_outline_rounded,
                                    color: AppColors.onSurfaceVariant,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '移除 ${_formatUserId(account.userId)}',
                                    style: TextStyle(
                                      color: AppColors.onSurfaceVariant,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    const SizedBox(height: 8),
                    // Logout current account
                    AppCard(
                      color: AppColors.error.withValues(alpha: 0.12),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      onTap: () =>
                          _removeAccount(activeUserId ?? currentUser.id),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.logout_rounded,
                            color: AppColors.error,
                            size: 18,
                          ),
                          SizedBox(width: 8),
                          Text(
                            '退出登录',
                            style: TextStyle(
                              color: AppColors.error,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatCacheSize(int bytes) {
    const kilobyte = 1024;
    const megabyte = kilobyte * 1024;
    const gigabyte = megabyte * 1024;
    if (bytes >= gigabyte) {
      return '${(bytes / gigabyte).toStringAsFixed(1)} GB';
    }
    if (bytes >= megabyte) {
      return '${(bytes / megabyte).toStringAsFixed(1)} MB';
    }
    if (bytes >= kilobyte) {
      return '${(bytes / kilobyte).toStringAsFixed(1)} KB';
    }
    return '$bytes B';
  }

  String _formatUserId(String userId) {
    // @aka:matrix.local -> aka (matrix.local)
    final parts = userId.split(':');
    final local = parts.first.replaceFirst('@', '');
    final server = parts.length > 1 ? parts.sublist(1).join(':') : '';
    return server.isNotEmpty ? '$local ($server)' : local;
  }

  Widget _buildGroup({required String title, required List<Widget> items}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Text(
            title,
            style: const TextStyle(
              color: AppColors.onSurfaceVariant,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        AppCard(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: items),
        ),
      ],
    );
  }
}

class _SettingItem extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  const _SettingItem({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppRadii.tag),
              ),
              child: Icon(icon, color: iconColor, size: 18),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: AppColors.onBackground,
                      fontSize: 15,
                      fontWeight: onTap != null
                          ? FontWeight.w600
                          : FontWeight.w500,
                    ),
                  ),
                  if (subtitle.isNotEmpty)
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
            if (trailing != null)
              trailing!
            else if (onTap != null)
              const Icon(
                Icons.chevron_right_rounded,
                color: AppColors.onSurfaceVariant,
                size: 20,
              ),
          ],
        ),
      ),
    );
  }
}
