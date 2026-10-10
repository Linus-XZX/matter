import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_client_config.dart';
import 'push_avatar.dart';
import 'push_conversation.dart';
import 'push_payload.dart';
import 'push_reply.dart';
import 'push_room_directory.dart';
import 'push_settings.dart';

/// Per-account room metadata snapshot, shared with the notification path.
final _roomDirectory = PushRoomDirectory();

/// Accumulated per-room conversations, rebuilt on every background message.
final _conversations = PushConversationStore();

/// Fetched avatar bytes, cached across background isolate restarts.
final _avatars = PushAvatarStore();

/// Action id for the inline reply box on an Android notification.
const replyActionId = 'matter.reply';

/// Whether the event can be answered from the notification.
///
/// Replying to an encrypted room needs the SDK's Olm session and key store,
/// which the notification path deliberately does not start, so the reply
/// action is offered only for rooms whose message is sent as plaintext.
bool supportsInlineReply(Map<String, dynamic> data, {PushRoomInfo? room}) =>
    isMessageEvent(data) && !(room?.isEncrypted ?? false);

/// Handle a reply typed into a notification.
///
/// Runs on the plugin's background isolate, so it is annotated as an entry
/// point and reads only persisted state. Sending does not require the Rust
/// client, so no Matrix client is started here.
@pragma('vm:entry-point')
Future<void> handleNotificationReply(NotificationResponse response) async {
  if (response.actionId != replyActionId) return;
  final input = response.input?.trim() ?? '';
  final target = parsePushTargetPayload(response.payload);
  if (target == null || input.isEmpty) return;
  final room = await _roomDirectory.lookup(target.userId, target.roomId);
  // Re-check here rather than trusting the action's presence: the room's
  // encryption state may have changed since the notification was posted.
  if (room?.isEncrypted ?? false) {
    debugPrint('Refusing inline reply to an encrypted room');
    return;
  }
  final sent = await sendNotificationReply(
    userId: target.userId,
    roomId: target.roomId,
    body: input,
  );
  if (!sent) return;
  // Drop the conversation so the reply does not leave a stale notification
  // behind claiming the room is unread.
  await _conversations.clearRoom(target.userId, target.roomId);
}

/// Decode a notification payload into a target.
///
/// Shared by the background reply handler and the runtime's own handlers.
PushTarget? parsePushTargetPayload(String? payload) {
  if (payload == null || payload.isEmpty) return null;
  try {
    final data = jsonDecode(payload);
    return data is Map<String, dynamic> ? PushTarget.fromData(data) : null;
  } on FormatException {
    return null;
  }
}

Future<Uint8List?> _roomAvatarBytes(
  PushTarget target,
  PushRoomInfo? room,
  PushMediaSession? session,
) async {
  final mxc = room?.avatarMxc ?? '';
  if (mxc.isEmpty) return null;
  return loadAvatarBytes(
    store: _avatars,
    userId: target.userId,
    mxc: mxc,
    session: session,
  );
}

/// Avatar for the author of an encrypted-room message.
///
/// Skipped for encrypted rooms: those authors are not resolved for the
/// notification path, matching how other clients render a locked room.
Future<Uint8List?> _senderAvatarBytes(
  PushTarget target,
  Map<String, dynamic> data,
  PushRoomInfo? room,
  PushMediaSession? session,
) async {
  if (room?.isEncrypted ?? false) return null;
  final sender = pushSenderId(data);
  if (sender == null) return null;
  final mxc = await loadPushSenderAvatar(
    target.userId,
    target.roomId,
    sender,
  );
  if (mxc == null) return null;
  return loadAvatarBytes(
    store: _avatars,
    userId: target.userId,
    mxc: mxc,
    session: session,
  );
}

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
  // The reply handler must be registered on the isolate that owns the
  // notification, so the typed text is delivered to the background isolate
  // that the notification was posted from.
  await notifications.initialize(
    settings: _initializationSettings,
    onDidReceiveBackgroundNotificationResponse: handleNotificationReply,
  );
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
  // One session lookup and one avatar fetch per message; both are cached, and
  // a failure only costs the small icon.
  final session = await loadPushMediaSession(target.userId);
  final roomAvatar = await _roomAvatarBytes(target, room, session);
  final senderAvatar = await _senderAvatarBytes(target, data, room, session);
  final replyable = supportsInlineReply(data, room: room);
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
        // The large icon identifies the room at a glance. A direct chat shows
        // the author instead, which is the more useful identity there.
        largeIcon: isDirect
            ? _bitmap(senderAvatar) ?? _bitmap(roomAvatar)
            : _bitmap(roomAvatar),
        styleInformation: _conversationStyle(
          preview: preview,
          conversation: conversation,
          isDirect: isDirect,
          senderId: pushSenderId(data),
          senderAvatar: senderAvatar,
          roomAvatar: roomAvatar,
        ),
        actions: replyable
            ? [
                AndroidNotificationAction(
                  replyActionId,
                  '回复',
                  showsUserInterface: false,
                  // Typed text comes back as the action's input result.
                  inputs: const [AndroidNotificationActionInput()],
                ),
              ]
            : null,
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

/// Wrap fetched bytes as a notification large icon, or null when unavailable.
ByteArrayAndroidBitmap? _bitmap(Uint8List? bytes) =>
    bytes == null ? null : ByteArrayAndroidBitmap(bytes);

/// Wrap fetched bytes as a `Person` icon, or null when unavailable.
///
/// `Person.icon` takes an `AndroidIcon` rather than an `AndroidBitmap`, so the
/// two helpers are not interchangeable.
ByteArrayAndroidIcon? _icon(Uint8List? bytes) =>
    bytes == null ? null : ByteArrayAndroidIcon(bytes);

/// Render accumulated messages as an Android conversation.
///
/// The author is carried by each entry's [Person], which is why the stored
/// bodies omit the `Sender：` prefix shown in the collapsed form.
MessagingStyleInformation _conversationStyle({
  required PushPreview preview,
  required PushConversation conversation,
  required bool isDirect,
  required String? senderId,
  required Uint8List? senderAvatar,
  required Uint8List? roomAvatar,
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
          // Only the newest message's author was resolved, so earlier history
          // falls back to the room avatar rather than showing no icon.
          icon: _icon(
            entry.senderId == senderId ? senderAvatar ?? roomAvatar : roomAvatar,
          ),
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
        // A reply arrives on the background isolate even while the app runs.
        onDidReceiveBackgroundNotificationResponse: handleNotificationReply,
      );
      final launch = await notifications.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) {
        initialTarget = parsePushTargetPayload(launch?.notificationResponse?.payload);
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


  void _openPayload(String? payload) {
    final target = parsePushTargetPayload(payload);
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
        if (parsePushTargetPayload(notification.payload ?? notification.tag)
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
      final target = parsePushTargetPayload(notification.payload ?? notification.tag);
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
