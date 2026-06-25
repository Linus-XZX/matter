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
      roomId: '!room:example.org',
      eventId: r'$event',
      source: '**hello**',
      body: 'hello',
      formattedBody: '<strong>hello</strong>',
    );

    expect(
      await store.load(
        roomId: '!room:example.org',
        eventId: r'$event',
        body: 'hello',
        formattedBody: '<strong>hello</strong>',
      ),
      '**hello**',
    );

    await store.delete(roomId: '!room:example.org', eventId: r'$event');
    expect(
      await store.load(
        roomId: '!room:example.org',
        eventId: r'$event',
        body: 'hello',
        formattedBody: '<strong>hello</strong>',
      ),
      isNull,
    );
  });

  test('drops stale source after a remote edit', () async {
    await store.save(
      roomId: '!room:example.org',
      eventId: r'$event',
      source: '**hello**',
      body: 'hello',
      formattedBody: '<strong>hello</strong>',
    );

    expect(
      await store.load(
        roomId: '!room:example.org',
        eventId: r'$event',
        body: 'edited elsewhere',
        formattedBody: null,
      ),
      isNull,
    );
  });
}
