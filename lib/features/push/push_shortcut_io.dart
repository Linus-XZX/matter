import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:jni/jni.dart';
import 'package:jni_flutter/jni_flutter.dart';

/// Publish the room icon as Android's conversation shortcut icon.
///
/// JNI uses the application context, so this also works in an FCM background
/// engine without an Activity or an Activity-owned method channel.
Future<String?> publishPushShortcut(
  String id,
  String title,
  String? avatarPath,
) async {
  if (!Platform.isAndroid || avatarPath == null) return null;
  try {
    final shortcutClass = JClass.forName(
      'moe/aks/matter/PushConversationShortcut',
    );
    final context = androidApplicationContext;
    try {
      final published = shortcutClass.staticMethodId(
        'publish',
        '(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Z',
      )(shortcutClass, jboolean.type, [context, id, title, avatarPath]);
      return published ? id : null;
    } finally {
      context.release();
      shortcutClass.release();
    }
  } catch (error) {
    // Shortcut metadata is optional; an OS failure must not prevent delivery.
    debugPrint('Push conversation shortcut failed: ${error.runtimeType}');
    return null;
  }
}
