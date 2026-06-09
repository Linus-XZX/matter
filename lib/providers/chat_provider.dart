import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../src/rust/api/matrix.dart' as rust;

final chatRoomsProvider = FutureProvider<List<rust.ChatRoom>>((ref) async {
  final rooms = await rust.getChatRooms();
  return rooms;
});

final spacesProvider = FutureProvider<List<rust.Space>>((ref) async {
  final spaces = await rust.getSpaces();
  return spaces;
});

final selectedSpaceIdProvider = StateProvider<String>((ref) => 'all');

final contactsProvider = FutureProvider<List<rust.Contact>>((ref) async {
  final contacts = await rust.getContacts();
  return contacts;
});
