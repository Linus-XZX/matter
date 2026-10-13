import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/app.dart';
import 'package:matter/pages/chat/chat_list_item.dart';
import 'package:matter/pages/chat/chat_page.dart';
import 'package:matter/pages/chat/search_page.dart';
import 'package:matter/pages/contacts/contacts_page.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/providers/connection_provider.dart';
import 'package:matter/providers/hidden_rooms_provider.dart';
import 'package:matter/providers/mutable_state.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:matter/widgets/mobile_tab_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RustApi implements RustLibApi {
  @override
  Future<List<rust.AccountInfo>> crateApiMatrixListAccounts() async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
}

rust.ChatRoom _room(int index, {String? preview}) => rust.ChatRoom(
  id: '!room$index:example.org',
  name: 'Room $index',
  lastMessage: preview ?? 'Preview $index',
  lastMessageTime: '0',
  lastEventId: '',
  unreadCount: 0,
  isMarkedUnread: false,
  roomType: 'group',
  isEncrypted: false,
  isMuted: false,
  roomState: 'joined',
);

Future<ProviderContainer> _pumpApp(
  WidgetTester tester, {
  TextDirection direction = TextDirection.ltr,
}) async {
  final container = ProviderContainer(
    overrides: [
      allChatRoomsProvider.overrideWith((ref) async => []),
      spacesProvider.overrideWith((ref) async => []),
      contactsProvider.overrideWith((ref) async => []),
      ungroupedRoomsProvider.overrideWith((ref) async => []),
      syncStreamProvider.overrideWith((ref) => null),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildMaterialTheme(Brightness.light),
        builder: (context, child) =>
            Directionality(textDirection: direction, child: child!),
        home: const MatterApp(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() => tester.pumpWidget(const SizedBox()));
  return container;
}

Finder _destination(int index) => find.byType(NavigationDestination).at(index);

Finder _destinationIcon(int index) =>
    find.descendant(of: _destination(index), matching: find.byType(Icon)).first;

void _expectHighlight(WidgetTester tester, double page) {
  final bar = find.byKey(const ValueKey('material-dock'));
  expect(bar, findsOneWidget);
  final paint = find
      .descendant(of: bar, matching: find.byType(CustomPaint))
      .first;
  final origin = tester.getTopLeft(paint);
  final first = tester.getCenter(_destinationIcon(0)) - origin;
  final last = tester.getCenter(_destinationIcon(3)) - origin;
  final center = Offset.lerp(first, last, page / 3)!;
  expect(
    paint,
    paints..rrect(
      color: Theme.of(tester.element(find.byType(NavigationBar)))
          .colorScheme
          .secondaryContainer,
      rrect: RRect.fromRectAndRadius(
        Rect.fromCenter(center: center, width: 64, height: 32),
        const Radius.circular(16),
      ),
    ),
  );
}

void main() {
  setUpAll(() => RustLib.initMock(api: _RustApi()));
  tearDownAll(RustLib.dispose);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final page in [
    const ChatPage(),
    const ChatSearchPage(),
    const ContactsPage(),
  ]) {
    testWidgets('${page.runtimeType} has a rounded Material search field', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          allChatRoomsProvider.overrideWith((ref) async => []),
          contactsProvider.overrideWith((ref) async => []),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildMaterialTheme(Brightness.light),
            home: page,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final decorator = tester.widget<InputDecorator>(
        find.byType(InputDecorator).first,
      );
      final border =
          decorator.decoration.enabledBorder ?? decorator.decoration.border;
      expect(border, isA<OutlineInputBorder>());
      expect(
        (border! as OutlineInputBorder).borderRadius,
        BorderRadius.circular(28),
      );
      await tester.tap(find.byType(TextField).first, warnIfMissed: false);
      await tester.pumpAndSettle();
      final focused = tester.widget<InputDecorator>(
        find.byType(InputDecorator).first,
      );
      expect(
        (focused.decoration.focusedBorder! as OutlineInputBorder).borderRadius,
        BorderRadius.circular(28),
      );
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('room refresh preserves visible rows and scroll position', (
    tester,
  ) async {
    var response = Completer<List<rust.ChatRoom>>()
      ..complete(List.generate(30, _room));
    final container = ProviderContainer(
      overrides: [allChatRoomsProvider.overrideWith((ref) => response.future)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildMaterialTheme(Brightness.light),
          home: const ChatPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    final scrollable = find.byType(Scrollable).first;
    final scroll = tester.state<ScrollableState>(scrollable);
    final offset = scroll.position.pixels;
    final row = find.byType(ChatListItem).first;
    final state = tester.state(row);
    final name = tester.widget<ChatListItem>(row).room.name;
    response = Completer<List<rust.ChatRoom>>();
    container.invalidate(allChatRoomsProvider);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text(name), findsOneWidget);
    expect(state.mounted, isTrue);
    expect(tester.state<ScrollableState>(scrollable), same(scroll));
    expect(scroll.position.pixels, offset);
    response.complete(
      List.generate(30, (index) => _room(index, preview: 'Updated $index')),
    );
    await tester.pumpAndSettle();
    expect(find.text(name), findsOneWidget);
    expect(scroll.position.pixels, offset);
    expect(find.textContaining('Updated'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('returning home during a fetch keeps the existing list', (
    tester,
  ) async {
    var response = Completer<List<rust.ChatRoom>>()
      ..complete(List.generate(30, _room));
    final container = ProviderContainer(
      overrides: [
        allChatRoomsProvider.overrideWith((ref) => response.future),
        contactsProvider.overrideWith((ref) async => []),
        syncStreamProvider.overrideWith((ref) => null),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildMaterialTheme(Brightness.light),
          home: const MatterApp(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final chatState = tester.state(find.byType(ChatPage));
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    final offset = scroll.position.pixels;
    await tester.tap(_destination(2));
    await tester.pumpAndSettle();
    response = Completer<List<rust.ChatRoom>>();
    container.invalidate(allChatRoomsProvider);
    await tester.pump();
    await tester.tap(_destination(0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.state(find.byType(ChatPage)), same(chatState));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(ChatListItem), findsWidgets);
    expect(scroll.position.pixels, offset);
    response.complete(List.generate(30, _room));
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, offset);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('cached rows do not auto-select a room during refresh', (
    tester,
  ) async {
    var response = Completer<List<rust.ChatRoom>>()..complete([_room(0)]);
    final selected = <String>[];
    final container = ProviderContainer(
      overrides: [allChatRoomsProvider.overrideWith((ref) => response.future)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildMaterialTheme(Brightness.light),
          home: Scaffold(
            body: ChatPage(
              embedded: true,
              onRoomSelected: (room) => selected.add(room.id),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(selected, isNotEmpty);
    selected.clear();
    response = Completer<List<rust.ChatRoom>>();
    container.invalidate(allChatRoomsProvider);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.text('Room 0'), findsOneWidget);
    expect(selected, isEmpty);
    response.complete([_room(1)]);
    await tester.pumpAndSettle();
    expect(selected, everyElement('!room1:example.org'));
    expect(selected, isNotEmpty);
  });

  testWidgets('hiding a room still removes it immediately', (tester) async {
    final container = ProviderContainer(
      overrides: [
        allChatRoomsProvider.overrideWith((ref) async => [_room(0)]),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildMaterialTheme(Brightness.light),
          home: const ChatPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Room 0'), findsOneWidget);
    await container.read(hiddenRoomsProvider.notifier).hideRooms([
      '!room0:example.org',
    ]);
    await tester.pump();
    expect(find.text('Room 0'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('暂无聊天'), findsOneWidget);
  });

  testWidgets('account change does not keep the previous list during reload', (
    tester,
  ) async {
    var response = Completer<List<rust.ChatRoom>>()..complete([_room(0)]);
    final container = ProviderContainer(
      overrides: [
        activeUserIdProvider.overrideWith(
          () => MutableState('@alice:example.org'),
        ),
        allChatRoomsProvider.overrideWith((ref) {
          ref.watch(activeUserIdProvider);
          return response.future;
        }),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildMaterialTheme(Brightness.light),
          home: const ChatPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Room 0'), findsOneWidget);
    response = Completer<List<rust.ChatRoom>>();
    container.read(activeUserIdProvider.notifier).value = '@bob:example.org';
    await tester.pump();
    expect(find.text('Room 0'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    response.complete([_room(1)]);
    await tester.pumpAndSettle();
    expect(find.text('Room 1'), findsOneWidget);
  });

  for (final direction in TextDirection.values) {
    testWidgets(
      'Material highlight follows taps, reversals and swipes in $direction',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(400, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await _pumpApp(tester, direction: direction);
        final position = tester
            .widget<MobileTabView>(find.byType(MobileTabView))
            .position;
        _expectHighlight(tester, 0);
        await tester.tap(_destination(3));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 64));
        expect(position.value, inExclusiveRange(0, 3));
        _expectHighlight(tester, position.value);
        final before = position.value;
        await tester.tap(_destination(0));
        await tester.pump();
        expect(position.value, before);
        _expectHighlight(tester, before);
        await tester.pumpAndSettle();
        _expectHighlight(tester, 0);
        final gesture = await tester.startGesture(const Offset(200, 200));
        await gesture.moveBy(
          Offset(direction == TextDirection.ltr ? -100 : 100, 0),
        );
        await tester.pump();
        expect(position.value, inExclusiveRange(0, .5));
        _expectHighlight(tester, position.value);
        await tester.pump(const Duration(milliseconds: 200));
        await gesture.up();
        await tester.pumpAndSettle();
        _expectHighlight(tester, 0);
      },
    );
  }

  testWidgets(
    'Material highlight stays aligned with large labels and a bottom safe area',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.view.padding = const FakeViewPadding(bottom: 34);
      tester.view.viewPadding = const FakeViewPadding(bottom: 34);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _pumpApp(tester);
      _expectHighlight(tester, 0);
      await tester.tap(_destination(3));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 64));
      final position = tester
          .widget<MobileTabView>(find.byType(MobileTabView))
          .position;
      _expectHighlight(tester, position.value);
      await tester.pumpAndSettle();
      _expectHighlight(tester, 3);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('connection title fades between labels', (tester) async {
    final container = await _pumpApp(tester);
    container.read(connectionProvider.notifier).value =
        AppConnectionState.connected;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 64));
    expect(find.text('连接中…'), findsOneWidget);
    expect(find.text('Matter'), findsOneWidget);
    final opacity = find.ancestor(
      of: find.text('Matter'),
      matching: find.byType(Opacity),
    );
    expect(opacity, findsWidgets);
    expect(
      tester.widget<Opacity>(opacity.first).opacity,
      inExclusiveRange(0, 1),
    );
    await tester.pumpAndSettle();
    expect(find.text('连接中…'), findsNothing);
  });

  testWidgets('desktop destination changes have a visible transition', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpApp(tester);
    final navigation = find.byType(NavigationRail);
    await tester.tap(
      find.descendant(
        of: navigation,
        matching: find.byIcon(Icons.people_outline),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 64));
    final fades = find.ancestor(
      of: find.byType(ContactsPage),
      matching: find.byType(FadeTransition),
    );
    expect(fades, findsWidgets);
    expect(
      tester.widget<FadeTransition>(fades.first).opacity.value,
      inExclusiveRange(0, 1),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<FadeTransition>(fades.first).opacity.value, 1);
  });
}
