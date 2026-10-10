import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_client_config.dart';
import 'push_conversation.dart';
import 'push_payload.dart';
import 'push_room_directory.dart';
import 'push_settings.dart';

/// Per-account room metadata snapshot, shared with the notification path.
final _roomDirectory = PushRoomDirectory();

/// Accumulated per-room conversations, rebuilt on every background message.
final _conversations = PushConversationStore();

const _channelId = 'matrix_messages';
const _initializationSettings = InitializationSettings(
  android: AndroidInitializationSettings('ic_notification'),
);

bool get fcmPushSupported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

@pragma('vm:entry-point')
Future<void> handleFcmBackgroundMessage(RemoteMessage message) async {
  await Firebase.initializeApp();
  final notifications = FlutterLocalNotificationsPlugin();
  await notifications.initialize(settings: _initializationSettings);
  await showMatrixPush(notifications, message.data);
}

Future<bool> acceptsPushTarget(PushTarget target) async {
  final settings = await PushSettingsStore().load(target.userId);
  if (!target.acceptedBy(settings)) return false;
  final prefs = await SharedPreferences.getInstance();
  final removedKey =
      'matrix_session_removed_${base64Url.encode(utf8.encode(target.userId))}';
  if (prefs.containsKey(removedKey)) return false;
  final sessions =
      jsonDecode(prefs.getString('multi_sessions') ?? '[]') as List;
  return sessions.any((session) => session['user_id'] == target.userId);
}

Future<void> showMatrixPush(
  FlutterLocalNotificationsPlugin notifications,
  Map<String, dynamic> data, {
  bool Function()? isFocused,
}) async {
  final target = PushTarget.fromData(data);
  // Counts-only updates do not represent a new event. Ignore stale pushes
  // from an old gateway, disabled setting or removed account, too.
  if (target == null ||
      !await acceptsPushTarget(target) ||
      (isFocused?.call() ?? false)) {
    return;
  }
  final room = await _roomDirectory.lookup(target.userId, target.roomId);
  final preview = buildPushPreview(data, room: room);
  final isDirect = room?.isDirect ?? false;
  final conversation = await _conversations.append(
    target.userId,
    target.roomId,
    PushConversationEntry(
      senderId: pushSenderId(data) ?? '',
      senderName: pushSenderName(data) ?? '',
      // Stored without the sender prefix: the messaging style renders the
      // author through its own Person entry.
      body: pushMessageText(data),
      eventId: target.eventId,
      receivedAtMillis: DateTime.now().millisecondsSinceEpoch,
    ),
  );
  await notifications.show(
    // Identity is stable per room: Android keys a notification by (tag, id),
    // so an event-specific tag would post a new notification per message
    // instead of updating the conversation in place.
    id: pushRoomNotificationId(target.userId, target.roomId),
    title: preview.title,
    body: preview.body,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        '聊天消息',
        channelDescription: 'Matrix 聊天消息推送',
        importance: Importance.high,
        priority: Priority.high,
        visibility: NotificationVisibility.private,
        // Group by room, not by account: Android collapses a conversation's
        // notifications together, which is what a chat notification should do.
        groupKey: 'matrix:${target.userId}:${target.roomId}',
        styleInformation: _conversationStyle(
          preview: preview,
          conversation: conversation,
          isDirect: isDirect,
        ),
        // Android's active-notification query exposes tags, not payloads.
        // A stable tag plus a stable id keeps one notification per room; the
        // latest event id travels in the payload, which Android ignores for
        // identity.
        tag: pushRoomTag(
          userId: target.userId,
          roomId: target.roomId,
          registrationId: target.registrationId,
        ),
      ),
    ),
    payload: jsonEncode(target.toData()),
  );
}

/// Render accumulated messages as an Android conversation.
///
/// The author is carried by each entry's [Person], which is why the stored
/// bodies omit the `Sender：` prefix shown in the collapsed form.
MessagingStyleInformation _conversationStyle({
  required PushPreview preview,
  required PushConversation conversation,
  required bool isDirect,
}) => MessagingStyleInformation(
  // Only used to label the user's own messages, which a push never contains;
  // the account display name is not in the payload, so fall back to a label.
  const Person(name: '我'),
  // A direct chat has no conversation title: Android then shows the sender
  // name alone, matching how the collapsed notification reads.
  conversationTitle: isDirect ? null : preview.groupTitle,
  groupConversation: !isDirect,
  messages: [
    for (final entry in conversation.entries)
      Message(
        entry.body,
        DateTime.fromMillisecondsSinceEpoch(entry.receivedAtMillis),
        Person(
          name: entry.senderName.isEmpty ? null : entry.senderName,
          key: entry.senderId.isEmpty ? null : entry.senderId,
        ),
      ),
  ],
);

class FcmPushRuntime {
  final notifications = FlutterLocalNotificationsPlugin();
  final _opened = StreamController<PushTarget>.broadcast();
  Stream<PushTarget> get opened => _opened.stream;
  PushTarget? initialTarget;
  String? initializationError;
  FirebaseClientConfig? configuration;
  bool configurationChanged = false;
  bool get isConfigured => configuration != null && !configurationChanged;
  Future<void>? _initialization;

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    if (!fcmPushSupported) return;
    try {
      configuration = await FirebaseClientConfigStore().load();
      if (configuration == null) return;
      await Firebase.initializeApp(options: configuration!.options);
      FirebaseMessaging.onBackgroundMessage(handleFcmBackgroundMessage);
      await notifications.initialize(
        settings: _initializationSettings,
        onDidReceiveNotificationResponse: (response) =>
            _openPayload(response.payload),
      );
      final launch = await notifications.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) {
        initialTarget = _parsePayload(launch?.notificationResponse?.payload);
      }
      FirebaseMessaging.onMessage.listen((message) {
        unawaited(
          showMatrixPush(
            notifications,
            message.data,
            isFocused: () =>
                WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed,
          ).catchError((Object error) {
            debugPrint(
              'Failed to display Matrix notification: ${error.runtimeType}',
            );
          }),
        );
      });
      // Also handle a gateway supplying an FCM notification payload.
      FirebaseMessaging.onMessageOpenedApp.listen((message) {
        final target = PushTarget.fromData(message.data);
        if (target != null) _opened.add(target);
      });
      final initialMessage = await FirebaseMessaging.instance
          .getInitialMessage();
      initialTarget ??= initialMessage == null
          ? null
          : PushTarget.fromData(initialMessage.data);
    } catch (error) {
      initializationError = 'FCM 初始化失败，请检查导入的 Firebase 配置和 Google Play 服务';
      debugPrint('FCM initialization failed: ${error.runtimeType}');
    }
  }

  PushTarget? _parsePayload(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final data = jsonDecode(payload);
      return data is Map<String, dynamic> ? PushTarget.fromData(data) : null;
    } on FormatException {
      return null;
    }
  }

  void _openPayload(String? payload) {
    final target = _parsePayload(payload);
    if (target != null) _opened.add(target);
  }

  Future<List<String>> roomNotificationEvents(
    String userId,
    String roomId,
  ) async {
    final active = await notifications.getActiveNotifications();
    return [
      for (final notification in active)
        // The payload holds the latest event id; the tag is now stable per
        // room and carries no event, so it is only a fallback for older
        // notifications posted before this change.
        if (_parsePayload(notification.payload ?? notification.tag)
            case final target?
            when target.userId == userId && target.roomId == roomId)
          target.eventId,
    ];
  }

  Future<void> cancelRoomNotifications(
    String userId,
    String roomId,
    List<String> eventIds,
  ) async {
    final readEvents = eventIds.toSet();
    for (final notification in await notifications.getActiveNotifications()) {
      final target = _parsePayload(notification.payload ?? notification.tag);
      // One notification represents the whole conversation, so its payload
      // carries only the newest event. Cancelling it also drops the
      // accumulated messages, otherwise the next message would resurface
      // everything already read.
      if (target != null &&
          target.userId == userId &&
          target.roomId == roomId &&
          readEvents.contains(target.eventId)) {
        if (notification.id != null) {
          await notifications.cancel(
            id: notification.id!,
            tag: notification.tag,
          );
        }
        await _conversations.clearRoom(userId, roomId);
      }
    }
  }

  Future<void> retireToken() async {
    if (configuration != null && initializationError == null) {
      await FirebaseMessaging.instance.deleteToken();
    }
  }

  void _checkConfiguration() {
    if (configurationChanged) {
      throw StateError('Firebase 配置已更换，请在系统设置中强行停止 Matter 后重新打开');
    }
    if (configuration == null) {
      throw StateError('请先导入 Android google-services.json');
    }
  }

  Future<void> requestPermission() async {
    await initialize();
    _checkConfiguration();
    if (initializationError != null) throw StateError(initializationError!);
    final permission = await FirebaseMessaging.instance.requestPermission();
    if (permission.authorizationStatus != AuthorizationStatus.authorized) {
      throw StateError('通知权限未授予，请在系统设置中允许 Matter 通知');
    }
  }

  Future<String> getToken() async {
    await initialize();
    _checkConfiguration();
    if (initializationError != null) throw StateError(initializationError!);
    final permission = await FirebaseMessaging.instance
        .getNotificationSettings();
    if (permission.authorizationStatus != AuthorizationStatus.authorized) {
      throw StateError('通知权限未授予，请在系统设置中允许 Matter 通知');
    }
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null || token.isEmpty) {
      throw StateError('无法获取 FCM 令牌，请检查 Google Play 服务和网络');
    }
    return token;
  }
}

final fcmPushRuntime = FcmPushRuntime();
