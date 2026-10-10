import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/push/push_conversation.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const alice = '@alice:example.org';
  const bob = '@bob:example.org';
  const room = '!room:example.org';

  PushConversationEntry entry(
    int sequence, {
    String senderName = 'Alice',
    String senderId = alice,
  }) => PushConversationEntry(
    senderId: senderId,
    senderName: senderName,
    body: '消息 $sequence',
    eventId: '\$event$sequence',
    receivedAtMillis: sequence,
  );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('PushConversation', () {
    test('keeps messages oldest first so Android reads them chronologically', () {
      final conversation = const PushConversation(
        entries: [],
        latestEventId: '',
        updatedAtMillis: 0,
      ).append(entry(1)).append(entry(2)).append(entry(3));
      expect(
        conversation.entries.map((e) => e.body),
        ['消息 1', '消息 2', '消息 3'],
      );
      expect(conversation.latestEventId, r'$event3');
    });

    test('drops the oldest messages past the cap, not the newest', () {
      var conversation = const PushConversation(
        entries: [],
        latestEventId: '',
        updatedAtMillis: 0,
      );
      for (var i = 1; i <= maxMessagesPerConversation + 3; i++) {
        conversation = conversation.append(entry(i));
      }
      expect(conversation.entries, hasLength(maxMessagesPerConversation));
      // A long conversation must show what just arrived, not what came first.
      expect(conversation.entries.last.body, '消息 ${maxMessagesPerConversation + 3}');
      expect(conversation.entries.first.body, '消息 4');
    });
  });

  group('PushConversationStore', () {
    test('accumulates successive messages for one room', () async {
      final store = PushConversationStore();
      await store.append(alice, room, entry(1));
      final merged = await store.append(alice, room, entry(2));
      expect(merged.entries.map((e) => e.body), ['消息 1', '消息 2']);
      // A fresh read must observe the same accumulation the background
      // isolate relies on: it rebuilds state from storage per message.
      final reloaded = await PushConversationStore().load(alice, room);
      expect(reloaded?.entries.map((e) => e.body), ['消息 1', '消息 2']);
    });

    test('keeps rooms and accounts apart', () async {
      final store = PushConversationStore();
      await store.append(alice, room, entry(1));
      await store.append(alice, '!other:example.org', entry(2));
      await store.append(bob, room, entry(3));
      expect((await store.load(alice, room))?.latestEventId, r'$event1');
      expect(
        (await store.load(alice, '!other:example.org'))?.latestEventId,
        r'$event2',
      );
      expect((await store.load(bob, room))?.latestEventId, r'$event3');
    });

    test('preserves the sender name so the style can label each message', () async {
      final store = PushConversationStore();
      await store.append(alice, room, entry(1));
      await store.append(
        alice,
        room,
        entry(2, senderName: 'Bob', senderId: bob),
      );
      final conversation = await store.load(alice, room);
      expect(conversation?.entries.map((e) => e.senderName), ['Alice', 'Bob']);
      expect(conversation?.entries.map((e) => e.senderId), [alice, bob]);
    });

    test('bounds stored rooms by dropping the quietest conversations', () async {
      final store = PushConversationStore();
      for (var i = 0; i < 30; i++) {
        await store.append(alice, '!room$i:example.org', entry(i + 1));
      }
      // The newest activity survives; the earliest is evicted to bound growth.
      expect(await store.load(alice, '!room29:example.org'), isNotNull);
      expect(await store.load(alice, '!room0:example.org'), isNull);
    });

    test('clearing one room keeps the others', () async {
      final store = PushConversationStore();
      await store.append(alice, room, entry(1));
      await store.append(alice, '!other:example.org', entry(2));
      await store.clearRoom(alice, room);
      expect(await store.load(alice, room), isNull);
      expect(await store.load(alice, '!other:example.org'), isNotNull);
    });

    test('clearing an account leaves other accounts intact', () async {
      final store = PushConversationStore();
      await store.append(alice, room, entry(1));
      await store.append(bob, room, entry(2));
      await store.clearAccount(alice);
      expect(await store.load(alice, room), isNull);
      expect(await store.load(bob, room), isNotNull);
    });

    test('recovers from a corrupt store instead of failing delivery', () async {
      SharedPreferences.setMockInitialValues({
        pushConversationsKey(alice): 'not json',
      });
      final store = PushConversationStore();
      expect(await store.load(alice, room), isNull);
      final merged = await store.append(alice, room, entry(1));
      expect(merged.entries.single.body, '消息 1');
    });
  });

  group('notification identity', () {
    test('is stable per room but distinct across rooms and accounts', () {
      expect(
        pushRoomNotificationId(alice, room),
        pushRoomNotificationId(alice, room),
      );
      expect(
        pushRoomNotificationId(alice, room),
        isNot(pushRoomNotificationId(alice, '!other:example.org')),
      );
      expect(
        pushRoomNotificationId(alice, room),
        isNot(pushRoomNotificationId(bob, room)),
      );
    });

    test('the tag carries no event, so one message does not spawn a new one', () {
      String tag() => pushRoomTag(
        userId: alice,
        roomId: room,
        registrationId: 'current',
      );
      expect(tag(), tag());
      expect(tag(), isNot(contains(r'$event')));
    });
  });
}
