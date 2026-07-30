sealed class RoomMetadataPatch {
  const RoomMetadataPatch({required this.roomId});

  final String roomId;
}

class RoomNamePatch extends RoomMetadataPatch {
  const RoomNamePatch({
    required super.roomId,
    required this.name,
    required this.nameEventId,
  });

  final String name;
  final String? nameEventId;
}

class RoomAvatarPatch extends RoomMetadataPatch {
  const RoomAvatarPatch({
    required super.roomId,
    required this.avatarUrl,
    required this.avatarEventId,
  });

  final String? avatarUrl;
  final String? avatarEventId;
}
