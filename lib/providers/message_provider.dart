import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../src/rust/api/matrix.dart' as rust;

final currentRoomIdProvider = StateProvider<String?>((ref) => null);

final messagesProvider = FutureProvider.family<List<rust.ChatMessage>, String>(
  (ref, roomId) async {
    final messages = await rust.getMessages(roomId: roomId);
    return messages;
  },
);
