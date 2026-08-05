class RoomStateEditTracker {
  bool _hasPendingEdit = false;
  String? _pendingEventId;
  final Set<String?> _supersededEventIds = {};

  void record({required String? currentEventId, required String? nextEventId}) {
    if (currentEventId == nextEventId) return;
    _supersededEventIds.add(currentEventId);
    _pendingEventId = nextEventId;
    _hasPendingEdit = true;
  }

  bool shouldAccept(String? eventId) {
    if (!_hasPendingEdit) return true;
    if (eventId == _pendingEventId) {
      clear();
      return true;
    }
    if (_supersededEventIds.contains(eventId)) return false;
    clear();
    return true;
  }

  void clear() {
    _hasPendingEdit = false;
    _pendingEventId = null;
    _supersededEventIds.clear();
  }
}
