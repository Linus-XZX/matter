import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'app.dart';
import 'pages/login/login_page.dart';
import 'providers/auth_provider.dart';
import 'providers/chat_provider.dart';
import 'providers/connection_provider.dart';
import 'src/rust/api/matrix.dart' as rust;
import 'src/rust/frb_generated.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: AppColors.background,
      systemNavigationBarIconBrightness: Brightness.light,
      systemNavigationBarDividerColor: Colors.transparent,
    ),
  );

  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  runApp(const ProviderScope(child: _AppRoot()));
}

class _AppRoot extends ConsumerStatefulWidget {
  const _AppRoot();

  @override
  ConsumerState<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends ConsumerState<_AppRoot> {
  bool _isRestoring = true;

  @override
  void initState() {
    super.initState();
    _tryRestoreSessions();
  }

  Future<void> _tryRestoreSessions() async {
    try {
      // Migrate legacy single-session format if present
      await migrateLegacySession();

      final sessions = await loadAllSessions();
      final activeId = await loadActiveUserId();

      if (sessions.isEmpty) {
        debugPrint('No sessions found');
        return;
      }

      final dataDir = (await getApplicationSupportDirectory()).path;
      String? restoredActiveId;
      String? restoredDisplayName;
      String? restoredHomeserver;

      // Restore all sessions, starting with the active one
      final orderedSessions = List<rust.StoredSession>.from(sessions);
      if (activeId != null) {
        // Move active session to front
        final activeIdx = orderedSessions.indexWhere(
          (s) => s.userId == activeId,
        );
        if (activeIdx > 0) {
          final active = orderedSessions.removeAt(activeIdx);
          orderedSessions.insert(0, active);
        }
      }

      for (final session in orderedSessions) {
        try {
          await rust.restoreSession(session: session, dataDir: dataDir);
          debugPrint('Restored session for ${session.userId}');

          if (restoredActiveId == null || session.userId == activeId) {
            restoredActiveId = session.userId;
            restoredHomeserver = session.homeserverUrl;
            restoredDisplayName = await loadDisplayName(session.userId);
          }
        } catch (e) {
          debugPrint('Failed to restore session for ${session.userId}: $e');
          // Remove corrupted session
          await removeSession(session.userId);
        }
      }

      // If we restored at least one session, set it as active
      if (restoredActiveId != null) {
        // Switch to the active account in Rust
        await rust.switchAccount(userId: restoredActiveId);

        ref.read(isLoggedInProvider.notifier).state = true;
        ref.read(currentUserProvider.notifier).state = CurrentUser(
          id: restoredActiveId,
          displayName:
              restoredDisplayName ??
              restoredActiveId.split(':').first.replaceFirst('@', ''),
          homeserver: restoredHomeserver ?? '',
        );
        ref.read(homeserverProvider.notifier).state = restoredHomeserver ?? '';
        ref.read(activeUserIdProvider.notifier).state = restoredActiveId;
        ref.read(sessionsProvider.notifier).state = await loadAllSessions();
        // Mark as connecting while we sync
        ref.read(connectionProvider.notifier).state =
            AppConnectionState.connecting;

        // Sync with retry
        for (var attempt = 0; attempt < 3; attempt++) {
          try {
            await rust.syncOnce();
            ref.invalidate(chatRoomsProvider);
            // Sync succeeded — mark connected
            ref.read(connectionProvider.notifier).state =
                AppConnectionState.connected;
            break;
          } catch (e) {
            debugPrint('Restore sync attempt ${attempt + 1} failed: $e');
            if (attempt < 2) {
              await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
            }
          }
        }
        try {
          await rust.startSync();
        } catch (e) {
          debugPrint('startSync after restore failed: $e');
        }
        // Initialize sync event listener for auto-refresh
        ref.read(syncStreamProvider);
        ref.invalidate(chatRoomsProvider);
      }
    } catch (e) {
      debugPrint('Session restore failed: $e');
    } finally {
      if (mounted) {
        setState(() => _isRestoring = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isRestoring) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.darkTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: ThemeMode.dark,
        home: const Scaffold(
          backgroundColor: AppColors.background,
          body: Center(
            child: CircularProgressIndicator(color: AppColors.primary),
          ),
        ),
      );
    }

    final isLoggedIn = ref.watch(isLoggedInProvider);

    return MaterialApp(
      title: 'Matter',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      home: isLoggedIn ? const MatterApp() : const LoginPage(),
    );
  }
}
