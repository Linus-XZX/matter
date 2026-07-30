import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../src/rust/api/matrix.dart' as rust;
import 'auth_provider.dart';
import 'connection_provider.dart';
import 'message_cache_persistence.dart';
import 'message_ordering.dart';
import 'mutable_state.dart';

final chatRoomsProvider = FutureProvider<List<rust.ChatRoom>>((ref) async {
  if (!ref.watch(sessionReadyProvider)) return [];
  final filter = await _previewIgnoreFilter(ref);
  final rooms = await rust.getChatRooms(
    ignoredUserIds: filter.ids?.toList(),
    authoritative: filter.authoritative,
  );
  return rooms;
});

final spacesProvider = FutureProvider<List<rust.Space>>((ref) async {
  if (!ref.watch(sessionReadyProvider)) return [];
  return rust.getSpaces();
});

final spaceDetailsProvider = FutureProvider.family<rust.SpaceDetails, String>((
  ref,
  spaceId,
) async {
  if (!ref.watch(sessionReadyProvider)) {
    throw StateError('Session not ready');
  }
  return rust.getSpaceDetails(spaceId: spaceId);
});

final inboxRoomsProvider = Provider<AsyncValue<List<rust.ChatRoom>>>((ref) {
  return ref
      .watch(chatRoomsProvider)
      .whenData(
        (rooms) => rooms.where((room) => room.roomType != 'space').toList(),
      );
});

final ungroupedRoomsProvider = FutureProvider<List<rust.ChatRoom>>((ref) async {
  if (!ref.watch(sessionReadyProvider)) return [];
  final filter = await _previewIgnoreFilter(ref);
  return rust.getUngroupedRooms(
    ignoredUserIds: filter.ids?.toList(),
    authoritative: filter.authoritative,
  );
});

final spaceChildrenProvider =
    FutureProvider.family<List<rust.ChatRoom>, String>((ref, spaceId) async {
      if (!ref.watch(sessionReadyProvider)) return [];
      final filter = await _previewIgnoreFilter(ref);
      return rust.getSpaceChildren(
        spaceId: spaceId,
        ignoredUserIds: filter.ids?.toList(),
        authoritative: filter.authoritative,
      );
    });

final contactsProvider = FutureProvider<List<rust.Contact>>((ref) async {
  if (!ref.watch(sessionReadyProvider)) return [];
  final contacts = await rust.getContacts();
  return contacts;
});

/// Server-backed ignore list. Chat timelines filter these senders immediately,
/// while the Matrix SDK applies the same policy to future sync events.
///
/// The last successfully fetched list is persisted per account so that a
/// loading or failed refresh never degrades into "nobody is ignored" and
/// re-exposes cached messages from ignored senders. When no snapshot exists
/// yet, the state is *unknown* — wait for the fetch (which itself falls back
/// to the SDK's local account-data store when offline, flagged `fromServer:
/// false` so it is served but never persisted or marked confirmed) instead
/// of rendering unfiltered.
/// Per-namespace count of live in-flight [ignoredUserIdsProvider] builds, and
/// namespaces whose revalidation was requested mid-build. Invalidating the
/// provider while a build is in flight permanently strands futures held on
/// that build, so write-through events arriving mid-build are deferred until
/// the build has fully completed.
final _ignoredListBuildsInFlight = <String, int>{};
final _ignoredListRevalidationPending = <String>{};

/// Records a revalidation request when a live build of
/// [ignoredUserIdsProvider] is in flight and returns true in that case.
/// Every revalidation source (sync events, confirmed write-throughs, refresh
/// completion, session changes) must defer this way instead of invalidating
/// directly:
/// invalidating mid-build permanently strands futures held on that build.
/// Deferred requests are drained by the provider's build-end hook.
bool _deferIgnoredListRevalidation(String namespace) {
  if ((_ignoredListBuildsInFlight[namespace] ?? 0) > 0) {
    _ignoredListRevalidationPending.add(namespace);
    return true;
  }
  return false;
}

/// Revalidate [ignoredUserIdsProvider] for [namespace], deferring while a
/// build is in flight (see [_deferIgnoredListRevalidation]). [invalidate]
/// does the actual invalidation when no build is in flight — callers pass
/// `ref.invalidateSelf` from the provider's own ref or
/// `() => ref.invalidate(ignoredUserIdsProvider)` from an external ref,
/// since a provider's own ref cannot invalidate itself by reference.
void _revalidateIgnoredUserIds(String namespace, void Function() invalidate) {
  if (!_deferIgnoredListRevalidation(namespace)) invalidate();
}

final ignoredUserIdsProvider = FutureProvider<Set<String>>((ref) async {
  if (!ref.watch(sessionReadyProvider)) return const <String>{};
  final namespace = ref.watch(activeUserIdProvider) ?? '';
  // Revalidate on confirmed write-throughs for this account. The publication
  // lives here — not in whichever widget triggered the write — so a
  // management page popped while its server request is still in flight
  // cannot leave the cached provider (and every open timeline) stale.
  var disposed = false;
  var buildReleased = false;
  void releaseBuild({required bool drainPending}) {
    if (buildReleased) return;
    buildReleased = true;
    final remaining = (_ignoredListBuildsInFlight[namespace] ?? 1) - 1;
    if (remaining == 0) {
      _ignoredListBuildsInFlight.remove(namespace);
    } else {
      _ignoredListBuildsInFlight[namespace] = remaining;
    }
    if (drainPending &&
        !disposed &&
        _ignoredListRevalidationPending.remove(namespace)) {
      ref.invalidateSelf();
    }
  }

  _ignoredListBuildsInFlight[namespace] =
      (_ignoredListBuildsInFlight[namespace] ?? 0) + 1;
  ref.onDispose(() {
    disposed = true;
    // A cancelled first load may never reach its finally block. Release its
    // namespace slot now, but leave pending work for a live build to drain.
    releaseBuild(drainPending: false);
  });
  final writeThroughs = _ignoredListWriteThroughs.stream.listen((changed) {
    if (changed != namespace || disposed) return;
    // Mid-build, the in-flight build already reconciles via its version
    // checks and post-change snapshot reads; revalidate once it finishes.
    _revalidateIgnoredUserIds(namespace, ref.invalidateSelf);
  });
  ref.onDispose(writeThroughs.cancel);
  try {
    return await _loadIgnoredUserIds(ref, namespace);
  } finally {
    // Revalidate only after this live build's future has completed:
    // invalidateSelf during a build strands held futures.
    scheduleMicrotask(() {
      releaseBuild(drainPending: true);
    });
  }
});

Future<Set<String>> _loadIgnoredUserIds(Ref ref, String namespace) async {
  // The in-memory confirmed list (set only from server-authoritative
  // sources: a completed write-through or a server fetch) outranks the
  // persisted snapshot, which stays best-effort — a SharedPreferences write
  // can fail after a confirmed write-through, leaving the snapshot stale.
  final persisted =
      _confirmedIgnoredLists[namespace] ??
      await _loadPersistedIgnoredUserIds(namespace);
  if (persisted != null) {
    unawaited(_refreshIgnoredUserIds(ref, namespace, persisted));
    return persisted;
  }
  final version = _ignoredListVersion(namespace);
  final result = await rust.getIgnoredUsers();
  final fresh = result.userIds.toSet();
  if (!result.fromServer) {
    // Offline store fallback: serve it (better than unknown on a first
    // run), but never persist or confirm it — the store can lag the latest
    // confirmed state in either direction and must not overwrite a
    // write-through snapshot later.
    return fresh;
  }
  if (_ignoredListVersion(namespace) == version) {
    await _enqueueIgnoredListWrite(namespace, version, () async {
      await _persistIgnoredUserIds(namespace, fresh);
    });
    // Re-check after the persist: a confirmed change may have landed while
    // the write was queued or on disk; this response is stale then.
    if (_ignoredListVersion(namespace) == version) {
      _confirmedIgnoredLists[namespace] = fresh;
      return fresh;
    }
  }
  // A confirmed change landed while this fetch (or its persist) was in
  // flight: the response is stale and must not become the provider state.
  // Serve the newer write-through snapshot instead; the read is queued
  // behind the change's own write so it observes the post-change snapshot.
  Set<String>? latest = _confirmedIgnoredLists[namespace];
  if (latest == null) {
    await _enqueueIgnoredListWrite(namespace, null, () async {
      latest = await _loadPersistedIgnoredUserIds(namespace);
    });
  }
  return latest ?? fresh;
}

const _kIgnoredUsersCachePrefix = 'ignored_users_v1';

/// The ignore list used to filter room-list previews, with its freshness.
/// Room collections watch it, so a write-through change re-filters previews
/// immediately (and an offline restart still filters via the persisted
/// snapshot). `ids` is null when the ignore state is unknown (no snapshot
/// and the fetch failed): Rust then falls back to its store-side filter
/// instead of treating the account as "nobody is ignored".
/// `authoritative` is true only when the served list matches the last
/// server-confirmed state (a successful write-through or completed fetch,
/// not superseded by a later `IgnoredUsersChanged`): Rust may then let the
/// list override its store, whose sync echo can lag in either direction. A
/// merely persisted cache is merged with the store instead.
Future<({Set<String>? ids, bool authoritative})> _previewIgnoreFilter(
  Ref ref,
) async {
  final namespace = ref.watch(activeUserIdProvider) ?? '';
  try {
    final ids = await ref.watch(ignoredUserIdsProvider.future);
    final confirmed = _confirmedIgnoredLists[namespace];
    return (
      ids: ids,
      authoritative: confirmed != null && setEquals(ids, confirmed),
    );
  } catch (_) {
    return (ids: null, authoritative: false);
  }
}

/// Returns the persisted ignore list, or null when no snapshot exists yet
/// (distinct from a persisted *empty* list).
Future<Set<String>?> _loadPersistedIgnoredUserIds(String namespace) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(
      '${_kIgnoredUsersCachePrefix}_$namespace',
    );
    return stored?.toSet();
  } catch (error) {
    debugPrint('loadPersistedIgnoredUserIds failed: $error');
    return null;
  }
}

Future<void> _persistIgnoredUserIds(String namespace, Set<String> ids) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final written = await prefs.setStringList(
      '${_kIgnoredUsersCachePrefix}_$namespace',
      ids.toList()..sort(),
    );
    if (!written) {
      // Best-effort persistence: the in-memory confirmed list still
      // protects this session, but warn that a restart would lose it.
      debugPrint(
        'persistIgnoredUserIds: setStringList returned false for '
        '$namespace; the snapshot was not updated.',
      );
    }
  } catch (error) {
    debugPrint('persistIgnoredUserIds failed: $error');
  }
}

/// Write the authoritative ignore list returned by a successful
/// `setUserIgnored` call through to the persisted snapshot for [namespace],
/// so timelines filter the affected sender immediately after the caller
/// revalidates [ignoredUserIdsProvider]. Without this, the provider would
/// keep serving the pre-change snapshot until a background server refresh
/// happens to succeed (and would restore it forever if that refresh keeps
/// failing). Persisting the full post-write list — rather than merging a
/// delta into a possibly unknown local baseline — also keeps other
/// already-ignored users when no snapshot exists yet.
/// Broadcasts the account namespace of every confirmed ignore-list
/// write-through. `ignoredUserIdsProvider` revalidates itself on these, so
/// the revalidation does not depend on the lifecycle of the widget that
/// triggered the write.
final _ignoredListWriteThroughs = StreamController<String>.broadcast();

Future<void> persistIgnoredUserList(String namespace, Set<String> ids) async {
  // Record the confirmed value synchronously: previews may treat the list as
  // authoritative from this point (the server has accepted the change), and
  // a later IgnoredUsersChanged demotes it again until revalidated.
  _confirmedIgnoredLists[namespace] = Set.unmodifiable(ids);
  // Bump synchronously so any refresh whose fetch started earlier is
  // recognized as stale when it completes. The queued write itself must
  // always run: queued writes execute in order, so rapid consecutive
  // changes apply in order instead of losing updates.
  _ignoredListWriteVersions[namespace] = _ignoredListVersion(namespace) + 1;
  await _enqueueIgnoredListWrite(namespace, null, () async {
    await _persistIgnoredUserIds(namespace, ids);
  });
  _ignoredListWriteThroughs.add(namespace);
}

Future<void> _refreshIgnoredUserIds(
  Ref ref,
  String namespace,
  Set<String> persisted,
) async {
  // Captured before the fetch: if a confirmed change bumps the version while
  // this refresh is in flight, its (stale) result must not overwrite the
  // write-through, nor revalidate the provider over newer state.
  final version = _ignoredListVersion(namespace);
  try {
    final result = await rust.getIgnoredUsers();
    if (!result.fromServer) {
      // Offline store fallback: it can lag a confirmed write-through in
      // either direction, so it must never REMOVE ids from the snapshot.
      final confirmed = _confirmedIgnoredLists[namespace];
      if (confirmed != null && setEquals(confirmed, persisted)) {
        // This snapshot IS a confirmed local write whose sync echo has not
        // arrived: the store is known to lag it, so the confirmed state
        // wins outright — unioning would resurrect e.g. a just-un-ignored
        // sender. Only an unconfirmed list (or one demoted by a genuine
        // IgnoredUsersChanged) may absorb store additions.
        return;
      }
      // The store may already hold cross-device additions the persisted
      // snapshot missed — union conservatively so Dart timelines (which
      // filter on this list alone) hide those senders too. Only a
      // server-authoritative result may shrink the list or be confirmed.
      final merged = {...persisted, ...result.userIds};
      if (merged.length != persisted.length) {
        await _enqueueIgnoredListWrite(namespace, version, () async {
          await _persistIgnoredUserIds(namespace, merged);
        });
        if (_ignoredListVersion(namespace) == version) {
          _revalidateIgnoredUserIds(namespace, ref.invalidateSelf);
        }
      }
      return;
    }
    final fresh = result.userIds.toSet();
    await _enqueueIgnoredListWrite(namespace, version, () async {
      await _persistIgnoredUserIds(namespace, fresh);
    });
    if (_ignoredListVersion(namespace) == version) {
      // The fetch completed against the current version: the persisted
      // snapshot now reflects a server-confirmed state, so previews may
      // treat it as authoritative again.
      final confirmed = _confirmedIgnoredLists[namespace];
      final wasConfirmed = confirmed != null && setEquals(confirmed, fresh);
      _confirmedIgnoredLists[namespace] = fresh;
      // Revalidate dependents when the content changed OR the freshness
      // just upgraded (cached → confirmed): the list value alone does not
      // carry freshness, and a stale store may still hide a sender the
      // confirmed list has un-ignored. When both are unchanged, skip the
      // invalidation — it would re-trigger this refresh in a loop.
      if (!wasConfirmed ||
          fresh.length != persisted.length ||
          !fresh.containsAll(persisted)) {
        _revalidateIgnoredUserIds(namespace, ref.invalidateSelf);
      }
    }
  } catch (error) {
    // Keep the persisted snapshot: an unknown server state must not be
    // treated as an empty ignore list.
    debugPrint('refreshIgnoredUserIds failed: $error');
  }
}

final _ignoredListWriteVersions = <String, int>{};
final _ignoredListWriteQueues = <String, List<Future<void> Function()>>{};

/// The last server-confirmed ignore list per account — set by a successful
/// write-through ([persistIgnoredUserList]) or a completed fetch, removed
/// when an `IgnoredUsersChanged` sync event makes it suspect. A served list
/// equal to this value may override the lagging SDK store in Rust; anything
/// else is only merged with the store.
final _confirmedIgnoredLists = <String, Set<String>>{};

int _ignoredListVersion(String namespace) =>
    _ignoredListWriteVersions[namespace] ?? 0;

/// Serializes persisted ignore-list writes per account. When
/// [expectedVersion] is given, the write runs only if the list's version
/// still equals it — a confirmed change ([persistIgnoredUserList]) bumps
/// the version synchronously, so a refresh whose fetch started before that
/// change is dropped instead of overwriting the newer snapshot. Confirmed
/// changes pass null: their queued writes always run, in order.
///
/// The returned future is created in the caller's zone and the drain starts
/// in the caller's zone, so this stays safe when callers live in different
/// zones (e.g. separate `testWidgets` bodies with their own FakeAsync).
Future<void> _enqueueIgnoredListWrite(
  String namespace,
  int? expectedVersion,
  Future<void> Function() write,
) {
  final completer = Completer<void>();
  final queue = _ignoredListWriteQueues.putIfAbsent(namespace, () => []);
  queue.add(() async {
    try {
      if (expectedVersion == null ||
          _ignoredListVersion(namespace) == expectedVersion) {
        await write();
      }
      completer.complete();
    } catch (error) {
      completer.completeError(error);
    }
  });
  if (queue.length == 1) unawaited(_drainIgnoredListWrites(namespace));
  return completer.future;
}

Future<void> _drainIgnoredListWrites(String namespace) async {
  final queue = _ignoredListWriteQueues[namespace]!;
  while (queue.isNotEmpty) {
    await queue.first();
    queue.removeAt(0);
  }
}

class RoomUnreadOverride {
  final bool unread;
  final int baselineUnreadCount;
  final bool baselineMarkedUnread;

  /// Latest-event ID of the snapshot the override supersedes. A room can
  /// advance without changing the unread counters (one unread is marked
  /// read, then another message arrives before the refresh: count is 1
  /// again), and millisecond timestamps can collide between events, so only
  /// the event ID reliably recognizes a newer snapshot.
  final String baselineLastEventId;

  const RoomUnreadOverride({
    required this.unread,
    required this.baselineUnreadCount,
    required this.baselineMarkedUnread,
    required this.baselineLastEventId,
  });

  bool appliesTo(rust.ChatRoom room) =>
      room.unreadCount == baselineUnreadCount &&
      room.isMarkedUnread == baselineMarkedUnread &&
      room.lastEventId == baselineLastEventId;
}

/// Optimistic unread state tied to the exact server snapshot it supersedes.
///
/// Any newer snapshot, including one containing a newly arrived message,
/// invalidates the override instead of letting an old "read" action hide it.
final roomUnreadOverrideProvider =
    NotifierProvider.family<
      MutableState<RoomUnreadOverride?>,
      RoomUnreadOverride?,
      String
    >((_) => MutableState(null));

/// Prevents background timeline refreshes from undoing an explicit unread
/// action. Opening the room again clears the suppression.
final roomAutoReadSuppressedProvider =
    NotifierProvider.family<MutableState<bool>, bool, String>(
      (_) => MutableState(false),
    );

RoomUnreadOverride? _roomUnreadOverrideFor(
  rust.ChatRoom room, {
  required bool unread,
}) {
  final syncedUnread = room.unreadCount > 0 || room.isMarkedUnread;
  return syncedUnread == unread
      ? null
      : RoomUnreadOverride(
          unread: unread,
          baselineUnreadCount: room.unreadCount,
          baselineMarkedUnread: room.isMarkedUnread,
          baselineLastEventId: room.lastEventId,
        );
}

void setRoomUnreadOverride(
  WidgetRef ref,
  rust.ChatRoom room, {
  required bool unread,
}) {
  ref.read(roomUnreadOverrideProvider(room.id).notifier).value =
      _roomUnreadOverrideFor(room, unread: unread);
}

void setRoomUnreadOverrideById(
  WidgetRef ref,
  String roomId, {
  required bool unread,
}) {
  final rooms = ref.read(chatRoomsProvider).asData?.value;
  if (rooms == null) return;
  for (final room in rooms) {
    if (room.id == roomId) {
      setRoomUnreadOverride(ref, room, unread: unread);
      return;
    }
  }
}

void invalidateSessionCollections(WidgetRef ref) {
  ref.invalidate(chatRoomsProvider);
  ref.invalidate(spacesProvider);
  ref.invalidate(ungroupedRoomsProvider);
  ref.invalidate(contactsProvider);
  final ignoredNamespace = ref.read(activeUserIdProvider) ?? '';
  if (!_deferIgnoredListRevalidation(ignoredNamespace)) {
    ref.invalidate(ignoredUserIdsProvider);
  }
  ref.invalidate(roomKnockRequestsProvider);
  ref.invalidate(roomUnreadOverrideProvider);
  ref.invalidate(roomAutoReadSuppressedProvider);
}

/// Drop the per-account ignore-list freshness and invalidate any refresh
/// still in flight for [namespace]. Session teardown and (re-)establishment
/// must reset this: while a session is down the sync subscription is
/// stopped, so the IgnoredUsersChanged that would normally demote a stale
/// confirmed list can be missed, and a previous session's confirmed list
/// must never mark the persisted snapshot authoritative for a new session.
void resetIgnoredListAccountState(String namespace) {
  _confirmedIgnoredLists.remove(namespace);
  _ignoredListWriteVersions[namespace] = _ignoredListVersion(namespace) + 1;
}

void clearActiveSessionState(WidgetRef ref, {bool markSessionReady = false}) {
  // Drop the ignore-list freshness of the outgoing account and invalidate
  // any refresh still in flight for it: while the session is down the sync
  // subscription is stopped, so the IgnoredUsersChanged that would normally
  // demote a stale confirmed list can be missed across a re-login.
  resetIgnoredListAccountState(ref.read(activeUserIdProvider) ?? '');
  ref.read(isLoggedInProvider.notifier).value = false;
  ref.read(currentUserProvider.notifier).value = null;
  ref.read(currentAccessTokenProvider.notifier).value = null;
  ref.read(activeUserIdProvider.notifier).value = null;
  ref.read(connectionProvider.notifier).value = AppConnectionState.disconnected;
  if (markSessionReady) {
    ref.read(sessionReadyProvider.notifier).value = true;
  }
}

Future<void> applyActiveSessionState(
  WidgetRef ref, {
  required String userId,
  required String displayName,
  required String homeserver,
  bool persistActiveUser = false,
  bool refreshStoredSessions = false,
  bool markLoggedIn = true,
}) async {
  // Every session (re-)establishment — login, account switch and its
  // rollback, startup restore — funnels through here. A confirmed ignore
  // list left over from a previous session of this account must not mark
  // the persisted snapshot authoritative: cross-device changes that landed
  // while the session was down were never demoted (the sync subscription is
  // off then), and a store-fallback refresh would cement the stale state.
  resetIgnoredListAccountState(userId);
  if (persistActiveUser) {
    await saveActiveUserId(userId);
  }
  final accessToken = await rust.getAccessToken();
  await syncStoredSessionTokens(userId);
  final sessions = refreshStoredSessions ? await loadAllSessions() : null;
  ref.read(currentUserProvider.notifier).value = CurrentUser(
    id: userId,
    displayName: displayName,
    homeserver: homeserver,
  );
  ref.read(currentAccessTokenProvider.notifier).value = accessToken;
  ref.read(homeserverProvider.notifier).value = homeserver;
  ref.read(activeUserIdProvider.notifier).value = userId;
  if (refreshStoredSessions) {
    ref.read(sessionsProvider.notifier).value = sessions ?? [];
  }
  if (markLoggedIn) {
    ref.read(isLoggedInProvider.notifier).value = true;
  }
  ref.read(connectionProvider.notifier).value = AppConnectionState.connecting;
  unawaited(refreshCurrentUserProfile(ref));
}

/// Fetch the server-side profile (display name + avatar) and merge it into
/// [currentUserProvider]. Fire-and-forget: failures keep the cached state.
Future<void> refreshCurrentUserProfile(WidgetRef ref) async {
  try {
    final profile = await rust.getProfile();
    final current = ref.read(currentUserProvider);
    if (current == null || current.id != profile.userId) return;
    // Construct directly instead of copyWith: a null profile.avatarUrl means
    // the avatar was deleted on the server and must clear the cached one.
    ref.read(currentUserProvider.notifier).value = CurrentUser(
      id: current.id,
      displayName: profile.displayName.isEmpty
          ? current.displayName
          : profile.displayName,
      avatarUrl: profile.avatarUrl,
      homeserver: current.homeserver,
    );
  } catch (_) {
    // Offline, session not ready, or caller widget disposed: keep cached state.
  }
}

Future<void> bootstrapActiveSessionSync(
  WidgetRef ref, {
  required String attemptLabel,
  required String startSyncLabel,
}) => bootstrapActiveSessionSyncForTest(
  ref,
  attemptLabel: attemptLabel,
  startSyncLabel: startSyncLabel,
  syncOnce: rust.syncOnce,
  startSync: rust.startSync,
  delay: (duration) => Future<void>.delayed(duration),
);

@visibleForTesting
Future<void> bootstrapActiveSessionSyncForTest(
  WidgetRef ref, {
  required String attemptLabel,
  required String startSyncLabel,
  required Future<void> Function() syncOnce,
  required Future<void> Function() startSync,
  required Future<void> Function(Duration duration) delay,
}) async {
  var initialSyncSucceeded = false;
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      await syncOnce();
      initialSyncSucceeded = true;
      ref.read(connectionProvider.notifier).value =
          AppConnectionState.connected;
      invalidateSessionCollections(ref);
      break;
    } catch (e) {
      debugPrint('$attemptLabel ${attempt + 1} failed: $e');
      if (attempt < 2) {
        await delay(Duration(seconds: 2 * (attempt + 1)));
      }
    }
  }

  if (!initialSyncSucceeded) {
    ref.read(connectionProvider.notifier).value =
        AppConnectionState.disconnected;
  }

  try {
    await startSync();
  } catch (e) {
    debugPrint('$startSyncLabel: $e');
    ref.read(connectionProvider.notifier).value =
        AppConnectionState.disconnected;
  }
  invalidateSessionCollections(ref);
}

final currentRoomIdProvider = NotifierProvider<MutableState<String?>, String?>(
  () => MutableState(null),
);

final messagesProvider = FutureProvider.family<List<rust.ChatMessage>, String>((
  ref,
  roomId,
) async {
  if (!ref.watch(sessionReadyProvider)) return const <rust.ChatMessage>[];
  return rust.getMessages(roomId: roomId);
});

Future<bool> _canPersistMessagesForRoom(dynamic read, String roomId) async {
  final knownRooms =
      (read(chatRoomsProvider) as AsyncValue<List<rust.ChatRoom>>)
          .asData
          ?.value;
  if (knownRooms != null) {
    for (final room in knownRooms) {
      if (room.id == roomId) {
        return !room.isEncrypted;
      }
    }
  }
  try {
    return !await rust.isRoomEncrypted(roomId: roomId);
  } catch (_) {
    return false;
  }
}

/// In-memory snapshot of the latest fetched messages per room.
///
/// The UI watches this instead of [messagesProvider] directly so that
/// re-entering a chat or receiving a sync event doesn't blank the list while
/// a fresh fetch is in flight. On first entry the disk cache is loaded into
/// here instantly (see [primeMessageCache]); later fetches update it via
/// [updateMessageCache]. See `message_cache_persistence.dart` for the disk
/// tier.
final messageCacheProvider =
    NotifierProvider.family<
      MutableState<List<rust.ChatMessage>>,
      List<rust.ChatMessage>,
      String
    >((_) => MutableState(const <rust.ChatMessage>[]));

final messageCachePrimedProvider =
    NotifierProvider.family<MutableState<bool>, bool, String>(
      (_) => MutableState(false),
    );

final messageCacheOwnerProvider =
    NotifierProvider.family<MutableState<String?>, String?, String>(
      (_) => MutableState(null),
    );

const unableToDecryptMessageContent = '无法解密此消息（缺少会话密钥）';

bool isUnableToDecryptPlaceholder(rust.ChatMessage message) {
  return message.msgType == rust.MessageType.text &&
      message.content == unableToDecryptMessageContent &&
      message.imageUrl == null &&
      message.mediaSourceJson == null;
}

rust.ChatMessage chooseMessageForSameEvent(
  rust.ChatMessage existing,
  rust.ChatMessage incoming,
) {
  final existingUnableToDecrypt = isUnableToDecryptPlaceholder(existing);
  final incomingUnableToDecrypt = isUnableToDecryptPlaceholder(incoming);
  if (existingUnableToDecrypt && !incomingUnableToDecrypt) return incoming;
  if (!existingUnableToDecrypt && incomingUnableToDecrypt) return existing;
  return incoming;
}

List<rust.ChatMessage> mergeMessageSnapshotAdditions(
  List<rust.ChatMessage> current,
  List<rust.ChatMessage> incoming,
) {
  if (incoming.isEmpty) return current;
  final byId = <String, rust.ChatMessage>{
    for (final message in current) message.id: message,
  };
  var changed = false;
  for (final message in incoming) {
    final existing = byId[message.id];
    if (existing == null) {
      byId[message.id] = message;
      changed = true;
      continue;
    }
    final selected = chooseMessageForSameEvent(existing, message);
    if (selected != existing) {
      byId[message.id] = selected;
      changed = true;
    }
  }
  if (!changed) return current;
  return byId.values.toList()..sort(compareChatMessages);
}

List<rust.ChatMessage> updateMessageCache(
  WidgetRef ref,
  String roomId,
  List<rust.ChatMessage> messages,
) {
  final current = ref.read(messageCacheProvider(roomId));
  final reconciled = reconcileMessageSnapshot(current, messages);
  if (current.length == reconciled.length) {
    var same = true;
    for (var i = 0; i < reconciled.length; i++) {
      if (reconciled[i] != current[i]) {
        same = false;
        break;
      }
    }
    if (same) return current;
  }
  ref.read(messageCacheProvider(roomId).notifier).value = reconciled;
  return reconciled;
}

/// Replaces the server's current window while retaining older cached history.
/// An empty refresh is treated as transient when a snapshot is already visible.
List<rust.ChatMessage> reconcileMessageSnapshot(
  List<rust.ChatMessage> current,
  List<rust.ChatMessage> latest,
) {
  if (latest.isEmpty) return current;
  if (current.isEmpty) return latest;

  final oldestLatestTimestamp = latest
      .map((message) => int.tryParse(message.timestamp) ?? 0)
      .reduce(math.min);
  final currentById = <String, rust.ChatMessage>{
    for (final message in current) message.id: message,
  };
  final byId = <String, rust.ChatMessage>{};
  for (final message in current) {
    if ((int.tryParse(message.timestamp) ?? 0) < oldestLatestTimestamp) {
      byId[message.id] = message;
    }
  }
  for (final message in latest) {
    final existing = currentById[message.id] ?? byId[message.id];
    byId[message.id] = existing == null
        ? message
        : chooseMessageForSameEvent(existing, message);
  }
  return byId.values.toList()..sort(compareChatMessages);
}

/// Populate the in-memory cache from disk for a room. Called once when a chat
/// is opened so the previous snapshot renders instantly while a network fetch
/// runs in the background. Safe to call repeatedly; no-ops after the first
/// successful priming for a given room.
Future<void> primeMessageCache(WidgetRef ref, String roomId) async {
  final namespace = ref.read(activeUserIdProvider) ?? 'anonymous';
  final allowDiskCache = await _canPersistMessagesForRoom(ref.read, roomId);
  final owner = ref.read(messageCacheOwnerProvider(roomId));
  if (owner != namespace) {
    ref.read(messageCacheProvider(roomId).notifier).value = const [];
    ref.read(messageCachePrimedProvider(roomId).notifier).value = false;
    ref.read(messageCacheOwnerProvider(roomId).notifier).value = namespace;
  }
  if (ref.read(messageCachePrimedProvider(roomId))) return;
  if (!allowDiskCache) {
    await clearCachedMessagesForRoom(namespace: namespace, roomId: roomId);
  }
  final cached = await loadCachedMessages(
    namespace: namespace,
    roomId: roomId,
    allowDiskRead: allowDiskCache,
  );
  final current = ref.read(messageCacheProvider(roomId));
  if (current.isEmpty && cached.isNotEmpty) {
    ref.read(messageCacheProvider(roomId).notifier).value = cached;
  }
  ref.read(messageCachePrimedProvider(roomId).notifier).value = true;
}

/// Background refresh of a room's messages that also reconciles the result into
/// the in-memory cache and the disk snapshot. Used by the UI in place of a
/// bare [messagesProvider] watch so the list never goes blank mid-fetch.
Future<void> refreshMessagesFromNetwork(WidgetRef ref, String roomId) async {
  final namespace = ref.read(activeUserIdProvider) ?? 'anonymous';
  ref.invalidate(messagesProvider(roomId));
  try {
    final latest = await ref.read(messagesProvider(roomId).future);
    if ((ref.read(activeUserIdProvider) ?? 'anonymous') != namespace) return;
    final allowDiskCache = await _canPersistMessagesForRoom(ref.read, roomId);
    if ((ref.read(activeUserIdProvider) ?? 'anonymous') != namespace) return;
    ref.read(messageCacheOwnerProvider(roomId).notifier).value = namespace;
    final reconciled = updateMessageCache(ref, roomId, latest);
    // Persist off the widget tree so a slow disk write never blocks the UI.
    Future.microtask(
      () => saveCachedMessages(
        namespace: namespace,
        roomId: roomId,
        messages: reconciled,
        persistToDisk: allowDiskCache,
      ),
    );
  } catch (_) {
    // Keep the existing cached snapshot on failure; the caller decides whether
    // to surface an error.
  }
}

const localOutgoingPendingPrefix = 'local_outgoing_pending:';
const localOutgoingSentPrefix = 'local_outgoing_sent:';
const localOutgoingFailedPrefix = 'local_outgoing_failed:';

bool isLocalOutgoingMessage(String id) =>
    id.startsWith(localOutgoingPendingPrefix) ||
    id.startsWith(localOutgoingSentPrefix) ||
    id.startsWith(localOutgoingFailedPrefix);

bool isLocalOutgoingSentMessage(String id) =>
    id.startsWith(localOutgoingSentPrefix);

bool isLocalOutgoingFailedMessage(String id) =>
    id.startsWith(localOutgoingFailedPrefix);

String failedLocalOutgoingId(String pendingId) {
  if (!pendingId.startsWith(localOutgoingPendingPrefix)) return pendingId;
  return '$localOutgoingFailedPrefix${pendingId.substring(localOutgoingPendingPrefix.length)}';
}

String sentLocalOutgoingId(String pendingId) {
  if (!pendingId.startsWith(localOutgoingPendingPrefix)) return pendingId;
  return '$localOutgoingSentPrefix${pendingId.substring(localOutgoingPendingPrefix.length)}';
}

class LocalOutgoingMessage {
  final rust.ChatMessage message;
  final String? sourceImageUrl;

  const LocalOutgoingMessage({required this.message, this.sourceImageUrl});
}

final localOutgoingMessagesProvider =
    NotifierProvider.family<
      MutableState<List<LocalOutgoingMessage>>,
      List<LocalOutgoingMessage>,
      String
    >((_) => MutableState(const <LocalOutgoingMessage>[]));

void upsertLocalOutgoingMessage(
  WidgetRef ref,
  String roomId,
  LocalOutgoingMessage message,
) {
  final messages = ref.read(localOutgoingMessagesProvider(roomId));
  final index = messages.indexWhere(
    (existing) => existing.message.id == message.message.id,
  );
  if (index == -1) {
    ref.read(localOutgoingMessagesProvider(roomId).notifier).value = [
      ...messages,
      message,
    ];
    return;
  }

  final next = [...messages];
  next[index] = message;
  ref.read(localOutgoingMessagesProvider(roomId).notifier).value = next;
}

void removeLocalOutgoingMessage(
  WidgetRef ref,
  String roomId,
  String messageId,
) {
  final messages = ref.read(localOutgoingMessagesProvider(roomId));
  ref.read(localOutgoingMessagesProvider(roomId).notifier).value = messages
      .where((message) => message.message.id != messageId)
      .toList();
}

String markLocalOutgoingMessageSent(
  WidgetRef ref,
  String roomId,
  String pendingId,
) {
  final sentId = sentLocalOutgoingId(pendingId);
  final messages = ref.read(localOutgoingMessagesProvider(roomId));
  final index = messages.indexWhere(
    (message) => message.message.id == pendingId,
  );
  if (index == -1) return sentId;

  final local = messages[index];
  final message = local.message;
  final next = [...messages];
  next[index] = LocalOutgoingMessage(
    message: rust.ChatMessage(
      id: sentId,
      senderId: message.senderId,
      senderName: message.senderName,
      content: message.content,
      formattedBody: message.formattedBody,
      caption: message.caption,
      captionFormattedBody: message.captionFormattedBody,
      mentionedUserIds: message.mentionedUserIds,
      mentionsRoom: message.mentionsRoom,
      timestamp: message.timestamp,
      isMe: message.isMe,
      msgType: message.msgType,
      imageUrl: message.imageUrl,
      mediaSourceJson: message.mediaSourceJson,
      imageWidth: message.imageWidth,
      imageHeight: message.imageHeight,
      inReplyTo: message.inReplyTo,
      isEdited: message.isEdited,
      editHistory: message.editHistory,
      reactions: message.reactions,
      readers: message.readers,
      totalMembers: message.totalMembers,
    ),
    sourceImageUrl: local.sourceImageUrl,
  );
  ref.read(localOutgoingMessagesProvider(roomId).notifier).value = next;
  return sentId;
}

Future<void> refreshMessagesRef(Ref ref, String roomId) async {
  final namespace = ref.read(activeUserIdProvider) ?? 'anonymous';
  ref.invalidate(messagesProvider(roomId));
  // Reconcile the fresh fetch into the in-memory cache + disk snapshot so the
  // UI (which watches messageCacheProvider) never has to flip through a
  // loading state. This is the path used by syncStreamProvider.
  try {
    final latest = await ref.read(messagesProvider(roomId).future);
    if (!ref.mounted) return;
    if ((ref.read(activeUserIdProvider) ?? 'anonymous') != namespace) return;
    final allowDiskCache = await _canPersistMessagesForRoom(ref.read, roomId);
    if (!ref.mounted) return;
    if ((ref.read(activeUserIdProvider) ?? 'anonymous') != namespace) return;
    ref.read(messageCacheOwnerProvider(roomId).notifier).value = namespace;
    final current = ref.read(messageCacheProvider(roomId));
    final reconciled = reconcileMessageSnapshot(current, latest);
    if (!identical(reconciled, current)) {
      ref.read(messageCacheProvider(roomId).notifier).value = reconciled;
    }
    unawaited(
      saveCachedMessages(
        namespace: namespace,
        roomId: roomId,
        messages: reconciled,
        persistToDisk: allowDiskCache,
      ),
    );
  } catch (_) {
    // Keep the existing snapshot on failure.
  }
}

Future<void> refreshMessages(WidgetRef ref, String roomId) {
  // Route through the cache-aware refresh so every caller (send, reaction,
  // etc.) keeps both the in-memory snapshot and the disk cache in sync.
  return refreshMessagesFromNetwork(ref, roomId);
}

final stickerPacksProvider =
    FutureProvider.family<List<rust.StickerPack>, String>((ref, roomId) async {
      if (!ref.watch(sessionReadyProvider)) return [];
      return rust.getStickerPacks(roomId: roomId);
    });

/// Convert mxc:// URI to HTTP URL for display.
/// Returns null if conversion fails or URL is not mxc://.
final mxcUrlCacheProvider =
    NotifierProvider<MutableState<Map<String, String>>, Map<String, String>>(
      () => MutableState({}),
    );

const _kMxcCachePrefix = 'mxc_http_cache_v1';
const _kMaxPersistedMxcEntriesPerUser = 500;
final _loadedMxcCacheUsers = <String>{};

String _mxcStorageNamespace(WidgetRef ref) =>
    ref.read(activeUserIdProvider) ?? 'anonymous';

String _mxcStorageKey(String namespace) => '${_kMxcCachePrefix}_$namespace';

String _scopedMxcCacheKey(String namespace, String cacheKey) =>
    '$namespace::$cacheKey';

Future<void> _ensureMxcCacheLoaded(WidgetRef ref) async {
  final namespace = _mxcStorageNamespace(ref);
  if (_loadedMxcCacheUsers.contains(namespace)) return;

  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_mxcStorageKey(namespace));
  if (raw != null && raw.isNotEmpty) {
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final trimmed = _trimPersistedMxcEntries(
        decoded.map((key, value) => MapEntry(key, '$value')),
      );
      final loadedEntries = decoded.map(
        (key, value) => MapEntry(
          _scopedMxcCacheKey(namespace, key),
          trimmed[key] ?? '$value',
        ),
      );
      final cache = ref.read(mxcUrlCacheProvider);
      ref.read(mxcUrlCacheProvider.notifier).value = {
        ...cache,
        ...loadedEntries,
      };
      if (trimmed.length != decoded.length) {
        await prefs.setString(_mxcStorageKey(namespace), jsonEncode(trimmed));
      }
    } catch (error) {
      debugPrint('Failed to load persisted MXC cache for $namespace: $error');
    }
  }

  _loadedMxcCacheUsers.add(namespace);
}

Future<void> _persistMxcCacheEntry(
  WidgetRef ref,
  String namespace,
  String unscopedCacheKey,
  String httpUrl,
) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final storageKey = _mxcStorageKey(namespace);
    final raw = prefs.getString(storageKey);
    final persisted = raw == null || raw.isEmpty
        ? <String, String>{}
        : (jsonDecode(raw) as Map<String, dynamic>).map(
            (key, value) => MapEntry(key, '$value'),
          );
    persisted.remove(unscopedCacheKey);
    persisted[unscopedCacheKey] = httpUrl;
    final trimmed = _trimPersistedMxcEntries(persisted);
    await prefs.setString(storageKey, jsonEncode(trimmed));
  } catch (error) {
    debugPrint('Failed to persist MXC cache entry: $error');
  }
}

Map<String, String> _trimPersistedMxcEntries(Map<String, String> entries) {
  if (entries.length <= _kMaxPersistedMxcEntriesPerUser) return entries;
  final trimmed = Map<String, String>.from(entries);
  while (trimmed.length > _kMaxPersistedMxcEntriesPerUser) {
    trimmed.remove(trimmed.keys.first);
  }
  return trimmed;
}

String _mxcCacheKey(String mxcUrl, {int? width, int? height}) {
  if (width == null && height == null) return mxcUrl;
  return '$mxcUrl|${width ?? 0}x${height ?? 0}';
}

String? cachedResolvedMxcUrl(
  WidgetRef ref,
  String? mxcUrl, {
  int? width,
  int? height,
}) {
  if (mxcUrl == null || !mxcUrl.startsWith('mxc://')) return null;
  final namespace = _mxcStorageNamespace(ref);
  final rawCacheKey = _mxcCacheKey(mxcUrl, width: width, height: height);
  final cacheKey = _scopedMxcCacheKey(namespace, rawCacheKey);
  return ref.read(mxcUrlCacheProvider)[cacheKey];
}

void rememberResolvedMxcUrl(
  WidgetRef ref,
  String? mxcUrl,
  String? httpUrl, {
  int? width,
  int? height,
}) {
  if (mxcUrl == null ||
      httpUrl == null ||
      !mxcUrl.startsWith('mxc://') ||
      httpUrl.isEmpty) {
    return;
  }
  final namespace = _mxcStorageNamespace(ref);
  final rawCacheKey = _mxcCacheKey(mxcUrl, width: width, height: height);
  final cacheKey = _scopedMxcCacheKey(namespace, rawCacheKey);
  final cache = ref.read(mxcUrlCacheProvider);
  if (cache[cacheKey] == httpUrl) return;
  ref.read(mxcUrlCacheProvider.notifier).value = {...cache, cacheKey: httpUrl};
  unawaited(_persistMxcCacheEntry(ref, namespace, rawCacheKey, httpUrl));
}

Future<String?> resolveMxcUrlAvatar(WidgetRef ref, String? mxcUrl) async {
  if (mxcUrl == null || !mxcUrl.startsWith('mxc://')) return null;
  await _ensureMxcCacheLoaded(ref);
  final namespace = _mxcStorageNamespace(ref);
  final rawCacheKey = _mxcCacheKey(mxcUrl, width: 96, height: 96);
  final cacheKey = _scopedMxcCacheKey(namespace, rawCacheKey);

  final cache = ref.read(mxcUrlCacheProvider);
  if (cache.containsKey(cacheKey)) return cache[cacheKey];

  try {
    final httpUrl = await rust.mxcToHttpAvatar(mxcUrl: mxcUrl);
    if (httpUrl == null || httpUrl.isEmpty) return null;
    ref.read(mxcUrlCacheProvider.notifier).value = {
      ...cache,
      cacheKey: httpUrl,
    };
    unawaited(_persistMxcCacheEntry(ref, namespace, rawCacheKey, httpUrl));
    return httpUrl;
  } catch (_) {
    return null;
  }
}

Future<String?> resolveMxcUrl(
  WidgetRef ref,
  String? mxcUrl, {
  int? width,
  int? height,
}) async {
  if (mxcUrl == null || !mxcUrl.startsWith('mxc://')) return null;
  await _ensureMxcCacheLoaded(ref);
  final namespace = _mxcStorageNamespace(ref);
  final rawCacheKey = _mxcCacheKey(mxcUrl, width: width, height: height);
  final cacheKey = _scopedMxcCacheKey(namespace, rawCacheKey);

  // Check cache first
  final cache = ref.read(mxcUrlCacheProvider);
  if (cache.containsKey(cacheKey)) return cache[cacheKey];

  try {
    final httpUrl = width != null && height != null
        ? await rust.mxcToHttpThumbnail(
            mxcUrl: mxcUrl,
            width: width,
            height: height,
          )
        : await rust.mxcToHttp(mxcUrl: mxcUrl);
    if (httpUrl == null || httpUrl.isEmpty) return null;
    ref.read(mxcUrlCacheProvider.notifier).value = {
      ...cache,
      cacheKey: httpUrl,
    };
    unawaited(_persistMxcCacheEntry(ref, namespace, rawCacheKey, httpUrl));
    return httpUrl;
  } catch (_) {
    return null;
  }
}

/// Convert mxc:// URI to full-quality download HTTP URL.
/// Used for "原图" (original quality) in image preview.
Future<String?> resolveMxcUrlFull(WidgetRef ref, String? mxcUrl) async {
  if (mxcUrl == null || !mxcUrl.startsWith('mxc://')) return null;
  try {
    return await rust.mxcToHttpFull(mxcUrl: mxcUrl);
  } catch (_) {
    return null;
  }
}

/// Room members provider
final roomMembersProvider = FutureProvider.family<List<rust.Contact>, String>((
  ref,
  roomId,
) async {
  if (!ref.watch(sessionReadyProvider)) return [];
  final members = await rust.getRoomMembers(roomId: roomId);
  return members;
});

final roomKnockRequestsProvider =
    FutureProvider.family<List<rust.KnockRequest>, String>((ref, roomId) async {
      if (!ref.watch(sessionReadyProvider)) return [];
      return rust.getRoomKnockRequests(roomId: roomId);
    });

/// Search rooms provider
final searchRoomsProvider = FutureProvider.family<List<rust.ChatRoom>, String>((
  ref,
  query,
) async {
  if (!ref.watch(sessionReadyProvider)) return [];
  if (query.trim().isEmpty) return [];
  final filter = await _previewIgnoreFilter(ref);
  return rust.searchRooms(
    query: query,
    ignoredUserIds: filter.ids?.toList(),
    authoritative: filter.authoritative,
  );
});

/// Send a reply to a message
Future<void> sendReply(
  Ref ref,
  String roomId,
  String message,
  String replyToEventId,
) async {
  await rust.sendReply(
    roomId: roomId,
    message: rust.FormattedMessageInput(
      body: message,
      mentionedUserIds: const [],
      mentionsRoom: false,
    ),
    replyToEventId: replyToEventId,
  );
  await refreshMessagesRef(ref, roomId);
  ref.invalidate(chatRoomsProvider);
}

/// Redact (delete) a message
Future<void> redactMessage(
  WidgetRef ref,
  String roomId,
  String eventId, {
  String? reason,
}) async {
  await rust.redactMessage(roomId: roomId, eventId: eventId, reason: reason);
  await refreshMessages(ref, roomId);
  ref.invalidate(chatRoomsProvider);
}

/// The sync event stream subscription. Stays active for the app's lifetime.
/// When sync events arrive, invalidates room/message providers so the UI
/// updates automatically.
///
/// Initialize once after login with: `ref.watch(syncStreamProvider);`
final syncStreamProvider =
    Provider.autoDispose<StreamSubscription<rust.SyncEvent>?>((ref) {
      final sessionReady = ref.watch(sessionReadyProvider);
      final activeUserId = ref.watch(activeUserIdProvider);
      if (!sessionReady || activeUserId == null) {
        return null;
      }

      final stream = rust.watchSyncEvents();
      Timer? messageRefreshTimer;
      Timer? roomRefreshTimer;
      final pendingMessageRefreshes = <String>{};
      final pendingReadAfterRefreshes = <String>{};
      var messageRefreshInFlight = false;
      var messageRefreshTrailing = false;
      var disposed = false;
      late void Function(String roomId, {bool markReadAfterRefresh})
      scheduleMessageRefresh;

      void refreshRooms() {
        if (disposed || !ref.mounted) return;
        ref.invalidate(chatRoomsProvider);
        ref.invalidate(spacesProvider);
        ref.invalidate(ungroupedRoomsProvider);
        ref.invalidate(spaceChildrenProvider);
        ref.invalidate(searchRoomsProvider);
        ref.invalidate(roomKnockRequestsProvider);
        ref.invalidate(roomMembersProvider);
      }

      void scheduleRoomRefresh() {
        if (disposed || !ref.mounted) return;
        roomRefreshTimer?.cancel();
        roomRefreshTimer = Timer(const Duration(milliseconds: 500), () {
          roomRefreshTimer = null;
          refreshRooms();
        });
      }

      Future<void> flushMessageRefreshes() async {
        if (disposed) return;
        if (messageRefreshInFlight) {
          messageRefreshTrailing = true;
          return;
        }
        final roomIds = pendingMessageRefreshes.toList();
        pendingMessageRefreshes.clear();
        final readAfterRefreshes = roomIds
            .where(pendingReadAfterRefreshes.remove)
            .toSet();
        if (roomIds.isEmpty) return;

        messageRefreshInFlight = true;
        try {
          await Future.wait(
            roomIds.map((roomId) async {
              await refreshMessagesRef(ref, roomId);
              if (disposed || !ref.mounted) return;
              if (!readAfterRefreshes.contains(roomId) ||
                  ref.read(currentRoomIdProvider) != roomId ||
                  ref.read(roomAutoReadSuppressedProvider(roomId))) {
                return;
              }
              rust.ChatRoom? unreadRoom;
              roomRefreshTimer?.cancel();
              roomRefreshTimer = null;
              try {
                final rooms = await ref.refresh(chatRoomsProvider.future);
                for (final room in rooms) {
                  if (room.id == roomId) {
                    unreadRoom = room;
                    break;
                  }
                }
              } catch (error) {
                debugPrint(
                  'refresh chat rooms before markRoomAsRead failed: $error',
                );
              }
              if (disposed || !ref.mounted) return;
              if (ref.read(currentRoomIdProvider) != roomId ||
                  ref.read(roomAutoReadSuppressedProvider(roomId))) {
                scheduleRoomRefresh();
                return;
              }
              try {
                await rust.markRoomAsRead(roomId: roomId);
                if (disposed || !ref.mounted) return;
                if (unreadRoom != null) {
                  ref.read(roomUnreadOverrideProvider(roomId).notifier).value =
                      _roomUnreadOverrideFor(unreadRoom, unread: false);
                }
              } catch (error) {
                debugPrint('markRoomAsRead after refresh failed: $error');
              }
              scheduleRoomRefresh();
            }),
          );
        } finally {
          messageRefreshInFlight = false;
          if (!disposed &&
              (messageRefreshTrailing || pendingMessageRefreshes.isNotEmpty)) {
            messageRefreshTrailing = false;
            for (final roomId in pendingMessageRefreshes.toList()) {
              scheduleMessageRefresh(roomId);
            }
          }
        }
      }

      scheduleMessageRefresh =
          (String roomId, {bool markReadAfterRefresh = false}) {
            if (disposed || !ref.mounted) return;
            pendingMessageRefreshes.add(roomId);
            if (markReadAfterRefresh) {
              pendingReadAfterRefreshes.add(roomId);
            }
            if (messageRefreshInFlight) {
              messageRefreshTrailing = true;
              return;
            }
            if (messageRefreshTimer != null) return;
            messageRefreshTimer = Timer(const Duration(milliseconds: 100), () {
              messageRefreshTimer = null;
              unawaited(flushMessageRefreshes());
            });
          };

      final statusTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => pollConnectionStatus(ref),
      );
      Future.microtask(() => pollConnectionStatus(ref));
      final subscription = stream.listen((event) {
        if (disposed || !ref.mounted) return;
        pollConnectionStatus(ref);
        switch (event) {
          case rust.SyncEvent_SyncCompleted():
            scheduleRoomRefresh();
            final currentRoomId = ref.read(currentRoomIdProvider);
            if (currentRoomId != null) {
              scheduleMessageRefresh(currentRoomId);
            }
          case rust.SyncEvent_RoomListChanged():
            scheduleRoomRefresh();
          case rust.SyncEvent_MessageSent(:final roomId):
            if (ref.read(currentRoomIdProvider) == roomId) {
              scheduleMessageRefresh(roomId, markReadAfterRefresh: true);
            }
            scheduleRoomRefresh();
          case rust.SyncEvent_IgnoredUsersChanged():
            // The account data changed outside a confirmed local write (or
            // its echo landed): the last confirmed list is now suspect, so
            // previews must merge with the store until revalidated. Bump
            // the version as well, so a refresh whose fetch started before
            // this event is dropped instead of writing back (and confirming)
            // a list that predates the change.
            final namespace = ref.read(activeUserIdProvider) ?? '';
            _confirmedIgnoredLists.remove(namespace);
            _ignoredListWriteVersions[namespace] =
                _ignoredListVersion(namespace) + 1;
            _revalidateIgnoredUserIds(
              namespace,
              () => ref.invalidate(ignoredUserIdsProvider),
            );
        }
      });

      ref.onDispose(() {
        disposed = true;
        statusTimer.cancel();
        messageRefreshTimer?.cancel();
        roomRefreshTimer?.cancel();
        pendingReadAfterRefreshes.clear();
        subscription.cancel();
      });

      return subscription;
    });

// ── Typing notifications ─────────────────────────────────────────────
//
// `typingUsersProvider(roomId)` exposes the set of user ids currently typing
// in that room. A single subscription to `watchTypingNotifications` fans out
// updates by room id; each room auto-clears after 5s of silence (Matrix typing
// events are ephemeral and may not always send an explicit "stopped" event).

final typingUsersProvider =
    NotifierProvider.family<MutableState<Set<String>>, Set<String>, String>(
      (_) => MutableState({}),
    );

/// Per-room timeout timers so typing status clears after inactivity.
final _typingTimers = <String, Timer>{};

/// Start the global typing-notification listener. Initialize once after login
/// (alongside `syncStreamProvider`). Returns the subscription.
final typingStreamProvider =
    Provider<StreamSubscription<rust.TypingNotification>?>((ref) {
      final sessionReady = ref.watch(sessionReadyProvider);
      final activeUserId = ref.watch(activeUserIdProvider);
      if (!sessionReady || activeUserId == null) {
        return null;
      }

      final stream = rust.watchTypingNotifications();
      final subscription = stream.listen((event) {
        final roomId = event.roomId;
        ref.read(typingUsersProvider(roomId).notifier).value = event.userIds
            .toSet();
        // (Re)arm the auto-clear timer for this room.
        _typingTimers[roomId]?.cancel();
        _typingTimers[roomId] = Timer(const Duration(seconds: 5), () {
          ref.read(typingUsersProvider(roomId).notifier).value = {};
          _typingTimers.remove(roomId);
        });
      });

      ref.onDispose(() {
        subscription.cancel();
        for (final t in _typingTimers.values) {
          t.cancel();
        }
        _typingTimers.clear();
      });

      return subscription;
    });
