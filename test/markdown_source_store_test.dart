import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/markdown/markdown_source_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const store = MarkdownSourceStore();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('stores source locally by room and event', () async {
    await store.save(
      userId: '@alice:example.org',
      roomId: '!room:example.org',
      eventId: r'$event',
      source: '**hello**',
      body: 'hello',
      formattedBody: '<strong>hello</strong>',
      persist: true,
    );

    expect(
      await store.load(
        userId: '@alice:example.org',
        roomId: '!room:example.org',
        eventId: r'$event',
        body: 'hello',
        formattedBody: '<strong>hello</strong>',
        allowPersistence: true,
      ),
      '**hello**',
    );

    await store.delete(
      userId: '@alice:example.org',
      roomId: '!room:example.org',
      eventId: r'$event',
    );
    expect(
      await store.load(
        userId: '@alice:example.org',
        roomId: '!room:example.org',
        eventId: r'$event',
        body: 'hello',
        formattedBody: '<strong>hello</strong>',
        allowPersistence: true,
      ),
      isNull,
    );
  });

  test('drops stale source after a remote edit', () async {
    await store.save(
      userId: '@alice:example.org',
      roomId: '!room:example.org',
      eventId: r'$event',
      source: '**hello**',
      body: 'hello',
      formattedBody: '<strong>hello</strong>',
      persist: true,
    );

    expect(
      await store.load(
        userId: '@alice:example.org',
        roomId: '!room:example.org',
        eventId: r'$event',
        body: 'edited elsewhere',
        formattedBody: null,
        allowPersistence: true,
      ),
      isNull,
    );
  });

  test('does not persist encrypted room source', () async {
    await store.save(
      userId: '@alice:example.org',
      roomId: '!room:example.org',
      eventId: r'$event',
      source: '**secret**',
      body: 'secret',
      formattedBody: '<strong>secret</strong>',
      persist: false,
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), isEmpty);
  });

  test('isolates source by account and clears one account', () async {
    for (final userId in ['@alice:example.org', '@bob:example.org']) {
      await store.save(
        userId: userId,
        roomId: '!room:example.org',
        eventId: r'$event',
        source: '**$userId**',
        body: userId,
        formattedBody: null,
        persist: true,
      );
    }

    await store.clearForUser('@alice:example.org');

    expect(
      await store.load(
        userId: '@alice:example.org',
        roomId: '!room:example.org',
        eventId: r'$event',
        body: '@alice:example.org',
        formattedBody: null,
        allowPersistence: true,
      ),
      isNull,
    );
    expect(
      await store.load(
        userId: '@bob:example.org',
        roomId: '!room:example.org',
        eventId: r'$event',
        body: '@bob:example.org',
        formattedBody: null,
        allowPersistence: true,
      ),
      '**@bob:example.org**',
    );
  });

  test('clears all accounts', () async {
    for (final userId in ['@alice:example.org', '@bob:example.org']) {
      await store.save(
        userId: userId,
        roomId: '!room:example.org',
        eventId: r'$event',
        source: '**hello**',
        body: 'hello',
        formattedBody: null,
        persist: true,
      );
    }

    await store.clearAll();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), isEmpty);
  });
}
