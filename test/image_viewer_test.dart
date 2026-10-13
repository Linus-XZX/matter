import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/image_viewer.dart';
import 'package:matter/pages/chat/image_message_bubble.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/providers/message_cache_persistence.dart';
import 'package:matter/pages/chat/message_group.dart';
import 'package:matter/pages/chat/message_input.dart'
    show editingDraftProvider, editingSendInFlightProvider;
import 'package:matter/providers/mutable_state.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/neu_test_theme.dart';

final pixel = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==',
  ),
);

class ImageApi implements RustLibApi {
  final thumbnails = <String>[];
  final originals = <String>[];
  final downloads = <String>[];
  final forwards = <String>[];
  Completer<String?>? originalPending;
  Completer<String?>? thumbnailPending;

  @override
  Future<Uint8List?> crateApiMatrixDownloadMediaBytes({
    required String mxcUrl,
  }) async {
    downloads.add(mxcUrl);
    return pixel;
  }

  @override
  Future<Uint8List> crateApiMatrixDownloadMediaSourceBytes({
    required String mediaSourceJson,
    int? maxSizeBytes,
  }) async {
    downloads.add(mediaSourceJson);
    return pixel;
  }

  @override
  Future<String> crateApiMatrixForwardMessage({
    required String sourceRoomId,
    required String targetRoomId,
    required String eventId,
    required rust.FormattedMessageInput text,
  }) async {
    forwards.add(eventId);
    return 'forwarded';
  }

  @override
  Future<String?> crateApiMatrixMxcToHttpThumbnail({
    required String mxcUrl,
    required int width,
    required int height,
  }) async {
    thumbnails.add(mxcUrl);
    return thumbnailPending?.future ??
        Future.value('https://example.org/thumbnail/${mxcUrl.split('/').last}');
  }

  @override
  Future<String?> crateApiMatrixMxcToHttp({required String mxcUrl}) async {
    thumbnails.add(mxcUrl);
    return 'https://example.org/thumbnail/${mxcUrl.split('/').last}';
  }

  @override
  Future<String?> crateApiMatrixMxcToHttpFull({required String mxcUrl}) async {
    originals.add(mxcUrl);
    return originalPending?.future ??
        Future.value('https://example.org/original/${mxcUrl.split('/').last}');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

rust.ChatMessage imageMessage(
  String id, {
  int? size,
  String? filename,
  String? mimeType,
  bool encrypted = false,
}) => rust.ChatMessage(
  id: id,
  senderId: '@alice:example.org',
  senderName: 'Alice',
  content: filename ?? '$id.png',
  timestamp: id == 'older' ? '100' : '200',
  isMe: false,
  msgType: rust.MessageType.image,
  imageUrl: encrypted ? null : 'mxc://example.org/$id',
  mediaSourceJson: encrypted
      ? '{"url":"mxc://example.org/$id","key":{}}'
      : null,
  mimeType: mimeType,
  imageWidth: 1600,
  imageHeight: 1200,
  fileSize: size,
  filename: filename,
  mentionedUserIds: const [],
  mentionsRoom: false,
  isEdited: false,
  editHistory: const [],
  reactions: const [],
  readers: const [],
  totalMembers: 2,
);

Future<void> pumpImages(
  WidgetTester tester,
  List<rust.ChatMessage> messages, {
  ValueChanged<String>? onJump,
  VoidCallback? onReply,
  ImageHistoryLoader? loadOlder,
  String account = 'image-tester',
  bool dark = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        activeUserIdProvider.overrideWith(() => MutableState(account)),
        chatRoomsProvider.overrideWith(
          (_) async => [
            const rust.ChatRoom(
              id: '!target:example.org',
              name: '目标会话',
              lastMessage: '',
              lastMessageTime: '0',
              lastEventId: '',
              unreadCount: 0,
              isMarkedUnread: false,
              roomType: 'group',
              isEncrypted: false,
              isMuted: false,
              roomState: 'joined',
            ),
          ],
        ),
      ],
      child: MaterialApp(
        theme: neuTestTheme(dark: dark),
        home: Scaffold(
          body: MessageGroupWidget(
            group: MessageGroup(
              senderId: messages.last.senderId,
              senderName: 'Alice',
              isMe: false,
              messages: [messages.last],
            ),
            roomId: '!room:example.org',
            messageIndex: {for (final message in messages) message.id: message},
            showAvatar: false,
            onMessageJumpRequested: onJump,
            onReplyRequested: onReply,
            loadOlderImages: loadOlder,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> openImage(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(ValueKey('msg-image:image-preview:$id')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  final toolbar = find.byKey(const ValueKey('image-viewer-toolbar'));
  final appBar = tester.widget<AppBar>(
    find.descendant(of: toolbar, matching: find.byType(AppBar)),
  );
  final background = appBar.backgroundColor!;
  final foreground = appBar.foregroundColor!;
  expect(background.a, 1);
  final backgroundLuminance = background.computeLuminance();
  final foregroundLuminance = foreground.computeLuminance();
  final lighter = backgroundLuminance > foregroundLuminance
      ? backgroundLuminance
      : foregroundLuminance;
  final darker = backgroundLuminance < foregroundLuminance
      ? backgroundLuminance
      : foregroundLuminance;
  expect((lighter + .05) / (darker + .05), greaterThanOrEqualTo(4.5));
  final toolbarRect = tester.getRect(toolbar);
  expect(toolbarRect.top, 0);
  expect(
    toolbarRect.height,
    kToolbarHeight + MediaQuery.paddingOf(tester.element(toolbar)).top,
  );
  final imageViewport = tester.getRect(
    find.descendant(
      of: find.byKey(ValueKey(id)),
      matching: find.byType(InteractiveViewer),
    ),
  );
  expect(imageViewport.top, greaterThanOrEqualTo(toolbarRect.bottom));
}

Future<void> chooseImageAction(
  WidgetTester tester,
  String id,
  String action,
) async {
  expect(find.byKey(ValueKey(id)), findsOneWidget);
  final toolbar = find.byKey(const ValueKey('image-viewer-toolbar'));
  final menuState = tester.state(
    find.descendant(
      of: toolbar,
      matching: find.byWidgetPredicate((widget) => widget is PopupMenuButton),
    ),
  );
  await tester.tap(
    find.descendant(of: toolbar, matching: find.byTooltip('更多操作')),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  expect(menuState.mounted, isTrue);
  await tester.tap(find.text(action));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

void main() {
  late ImageApi api;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = ImageApi();
    RustLib.initMock(api: api);
  });
  tearDown(RustLib.dispose);

  test('image metadata survives the message disk cache round trip', () {
    final message = imageMessage(
      'metadata',
      size: 123456,
      filename: 'animation',
      mimeType: 'image/gif',
    );
    final restored = chatMessageFromMap(chatMessageToMap(message));
    expect(restored.fileSize, 123456);
    expect(restored.mimeType, 'image/gif');
    expect(restored.filename, 'animation');
  });

  testWidgets(
    'original preference survives remount, eviction and is isolated by account',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'mxc_http_cache_v1_image-tester': jsonEncode({
          'mxc://example.org/persisted|original':
              'https://example.org/original/persisted',
          for (var i = 0; i < 501; i++)
            'mxc://example.org/cache-$i|96x96':
                'https://example.org/thumbnail/$i',
        }),
      });
      await pumpImages(tester, [imageMessage('persisted')]);
      expect(api.thumbnails, isEmpty);
      expect(api.originals, isEmpty);
      expect(
        tester
            .widget<CachedNetworkImage>(find.byType(CachedNetworkImage))
            .imageUrl,
        'https://example.org/original/persisted',
      );
      expect(
        tester
            .widget<CachedNetworkImage>(find.byType(CachedNetworkImage))
            .maxWidthDiskCache,
        isNull,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        jsonDecode(
          prefs.getString('mxc_http_cache_v1_image-tester')!,
        )['mxc://example.org/persisted|original'],
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox());
      await pumpImages(tester, [imageMessage('persisted')]);
      expect(api.thumbnails, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await pumpImages(tester, [
        imageMessage('persisted'),
      ], account: 'other-account');
      expect(api.thumbnails, ['mxc://example.org/persisted']);
    },
  );

  testWidgets('late thumbnail resolution cannot erase an original preference', (
    tester,
  ) async {
    api.thumbnailPending = Completer<String?>();
    late WidgetRef mediaRef;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              mediaRef = ref;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    final thumbnail = resolveMxcUrl(
      mediaRef,
      'mxc://example.org/race',
      width: 100,
      height: 100,
    );
    await tester.pump();
    await resolveMxcUrlFull(mediaRef, 'mxc://example.org/race');
    api.thumbnailPending!.complete('https://example.org/thumbnail/race');
    await thumbnail;
    expect(
      cachedOriginalMxcUrl(mediaRef, 'mxc://example.org/race'),
      'https://example.org/original/race',
    );
  });

  testWidgets('download and forwarding use the image selected after a swipe', (
    tester,
  ) async {
    String? suggestedName;
    const selector = MethodChannel('plugins.flutter.io/file_selector');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(selector, (call) async {
          if (call.method == 'getSavePath') {
            suggestedName = (call.arguments as Map)['suggestedName'] as String?;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(selector, null),
    );
    await pumpImages(tester, [imageMessage('older'), imageMessage('latest')]);
    await openImage(tester, 'latest');
    await tester.drag(find.byType(PageView), const Offset(650, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(
      tester.widget<PageView>(find.byType(PageView)).controller!.page,
      closeTo(0, .01),
    );
    final scrolling = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(PageView),
        matching: find.byType(Scrollable),
      ),
    );
    for (
      var frame = 0;
      frame < 40 && scrolling.position.isScrollingNotifier.value;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump();
    expect(scrolling.position.isScrollingNotifier.value, isFalse);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('image-viewer-toolbar')),
        matching: find.byTooltip('下载'),
      ),
    );
    await tester.pump();
    expect(api.downloads, ['mxc://example.org/older']);
    expect(suggestedName, 'older.png');
    await chooseImageAction(tester, 'older', '转发');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(
      find.byKey(const ValueKey('forward-room-!target:example.org')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(api.forwards, ['older']);
  });

  testWidgets(
    'encrypted image downloads decrypted bytes through its MediaSource',
    (tester) async {
      String? suggestedName;
      const selector = MethodChannel('plugins.flutter.io/file_selector');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(selector, (call) async {
            if (call.method == 'getSavePath') {
              suggestedName =
                  (call.arguments as Map)['suggestedName'] as String?;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(selector, null),
      );
      await pumpImages(tester, [imageMessage('encrypted', encrypted: true)]);
      await openImage(tester, 'encrypted');
      expect(api.downloads, ['{"url":"mxc://example.org/encrypted","key":{}}']);
      api.downloads.clear();
      await tester.tap(find.byTooltip('下载').hitTestable());
      await tester.pump();
      // The preview already has the decrypted original, so saving reuses it.
      expect(api.downloads, isEmpty);
      expect(suggestedName, 'encrypted.png');
    },
  );

  testWidgets(
    'loading older images preserves the current page and selects the preceding image',
    (tester) async {
      String? jumped;
      await pumpImages(
        tester,
        [imageMessage('latest')],
        onJump: (id) => jumped = id,
        loadOlder: () async => (
          messages: [imageMessage('older'), imageMessage('latest')],
          hasMore: false,
        ),
      );
      await openImage(tester, 'latest');
      await tester.tap(find.byTooltip('加载更早图片'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await chooseImageAction(tester, 'older', '转到消息');
      await tester.pump();
      expect(
        find.byWidgetPredicate((widget) => widget is PopupMenuItem),
        findsNothing,
      );
      expect(find.byType(ChatImageViewer), findsNothing);
      expect(jumped, 'older');
    },
  );

  testWidgets('reply quotes the selected gallery image and opens the input', (
    tester,
  ) async {
    final older = imageMessage('older', encrypted: true);
    final latest = imageMessage('latest');
    var replyRequests = 0;
    await pumpImages(tester, [older, latest], onReply: () => replyRequests++);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MessageGroupWidget)),
    );
    const key = (roomId: '!room:example.org', userId: 'image-tester');
    const otherKey = (roomId: '!room:example.org', userId: 'another-account');
    container.read(editingMessageProvider(key).notifier).value = latest;
    container.read(editingDraftProvider(key).notifier).value = (
      editingId: latest.id,
      text: 'unfinished edit',
    );
    container.read(replyingToProvider(otherKey).notifier).value = latest;
    await openImage(tester, 'latest');
    await tester.drag(find.byType(PageView), const Offset(650, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await chooseImageAction(tester, 'older', '回复');
    expect(find.byType(ChatImageViewer), findsNothing);
    expect(container.read(replyingToProvider(key)), same(older));
    expect(container.read(editingMessageProvider(key)), isNull);
    expect(container.read(editingDraftProvider(key)), isNull);
    expect(container.read(replyingToProvider(otherKey)), same(latest));
    expect(replyRequests, 1);
  });

  testWidgets('image reply preserves an edit being sent', (tester) async {
    final image = imageMessage('latest');
    var replyRequests = 0;
    await pumpImages(tester, [image], onReply: () => replyRequests++);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MessageGroupWidget)),
    );
    const key = (roomId: '!room:example.org', userId: 'image-tester');
    container.read(editingMessageProvider(key).notifier).value = image;
    container.read(editingSendInFlightProvider(key).notifier).value = image.id;
    await openImage(tester, 'latest');
    await chooseImageAction(tester, 'latest', '回复');
    expect(container.read(replyingToProvider(key)), isNull);
    expect(container.read(editingMessageProvider(key)), same(image));
    expect(container.read(editingSendInFlightProvider(key)), image.id);
    expect(replyRequests, 0);
    expect(find.text('编辑正在发送，请稍候'), findsOneWidget);
  });

  testWidgets('unsent local images do not offer reply', (tester) async {
    const id = 'local_outgoing_pending:photo';
    await pumpImages(tester, [imageMessage(id)], onJump: (_) {});
    await tester.tap(find.byType(ImageMessageBubble));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('回复'), findsNothing);
    expect(find.text('转到消息'), findsOneWidget);
  });

  testWidgets('open menu keeps its target while history changes the page', (
    tester,
  ) async {
    final history =
        Completer<({List<rust.ChatMessage> messages, bool hasMore})>();
    String? jumped;
    await pumpImages(
      tester,
      [imageMessage('latest')],
      onJump: (id) => jumped = id,
      loadOlder: () => history.future,
    );
    await openImage(tester, 'latest');
    await tester.tap(find.byTooltip('加载更早图片'));
    await tester.pump();
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    history.complete((
      messages: [
        imageMessage('older', size: 512 * 1024),
        imageMessage('latest'),
      ],
      hasMore: false,
    ));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.byTooltip('查看原图'), findsNothing);
    await tester.tap(find.text('转到消息'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(jumped, 'latest');
    expect(find.byType(ChatImageViewer), findsNothing);
  });

  testWidgets('toolbar and counter stay fixed while dragging images', (
    tester,
  ) async {
    await pumpImages(tester, [imageMessage('older'), imageMessage('latest')]);
    await openImage(tester, 'latest');
    final toolbar = find.byKey(const ValueKey('image-viewer-toolbar'));
    final counter = find.text('2 / 2');
    final image = find.descendant(
      of: find.byKey(const ValueKey('latest')),
      matching: find.byType(InteractiveViewer),
    );
    final toolbarRect = tester.getRect(toolbar);
    final counterRect = tester.getRect(counter);
    final imageRect = tester.getRect(image);
    final vertical = await tester.startGesture(imageRect.center);
    await vertical.moveBy(const Offset(0, 20));
    await tester.pump(const Duration(milliseconds: 16));
    await vertical.moveBy(const Offset(0, 40));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.getRect(image), isNot(imageRect));
    expect(tester.getRect(counter), counterRect);
    expect(tester.getRect(toolbar), toolbarRect);
    await vertical.cancel();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    final horizontal = await tester.startGesture(imageRect.center);
    await horizontal.moveBy(const Offset(20, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await horizontal.moveBy(const Offset(80, 0));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.getRect(image).left, greaterThan(imageRect.left));
    expect(tester.getRect(counter), counterRect);
    expect(tester.getRect(toolbar), toolbarRect);
    await horizontal.cancel();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets(
    'drag dismisses at 1x and zooming keeps drag and paging in the image',
    (tester) async {
      await pumpImages(tester, [imageMessage('older'), imageMessage('latest')]);
      await openImage(tester, 'latest');
      final viewer = find.byType(InteractiveViewer).hitTestable();
      final position = tester.getCenter(viewer);
      await tester.tapAt(position);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(position);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.widget<PageView>(find.byType(PageView)).physics,
        isA<NeverScrollableScrollPhysics>(),
      );
      await tester.drag(viewer, const Offset(0, 200));
      await tester.pump();
      expect(find.byType(ChatImageViewer), findsOneWidget);
      tester.widget<InteractiveViewer>(viewer).transformationController!.value =
          Matrix4.identity();
      await tester.pump();
      await tester.drag(viewer, const Offset(0, 200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(ChatImageViewer), findsNothing);
    },
  );

  testWidgets(
    'an original resolving during a swipe cannot change the selected image',
    (tester) async {
      api.originalPending = Completer<String?>();
      await pumpImages(tester, [imageMessage('older'), imageMessage('latest')]);
      await openImage(tester, 'latest');
      await tester.tap(find.text('原图').hitTestable());
      await tester.pump();
      await tester.drag(find.byType(PageView), const Offset(650, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      api.originalPending!.complete('https://example.org/original/latest');
      await tester.pump();
      expect(find.byTooltip('查看原图'), findsOneWidget);
      expect(find.byTooltip('正在加载原图'), findsNothing);
      expect(
        tester
            .widget<CachedNetworkImage>(
              find.descendant(
                of: find.byKey(const ValueKey('older')),
                matching: find.byType(CachedNetworkImage),
              ),
            )
            .imageUrl,
        'https://example.org/thumbnail/older',
      );
    },
  );

  testWidgets(
    'original resolution failure leaves a retry that can load the image',
    (tester) async {
      api.originalPending = Completer<String?>();
      await pumpImages(tester, [imageMessage('retry')]);
      await openImage(tester, 'retry');
      await tester.tap(find.text('原图'));
      await tester.pump();
      api.originalPending!.complete(null);
      await tester.pump();
      expect(find.text('重试'), findsOneWidget);
      api.originalPending = null;
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is CachedNetworkImage &&
              widget.imageUrl == 'https://example.org/original/retry',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('double tap cycles 2x, 4x and original scale', (tester) async {
    await pumpImages(tester, [imageMessage('zoom')]);
    await openImage(tester, 'zoom');
    final viewer = find.byType(InteractiveViewer);
    final position = tester.getCenter(viewer);
    for (final scale in [2.0, 4.0, 1.0]) {
      await tester.tapAt(position);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(position);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final widget = tester.widget<InteractiveViewer>(viewer);
      expect(widget.transformationController, isNotNull);
      expect(widget.transformationController!.value.getMaxScaleOnAxis(), scale);
      await tester.pump(const Duration(milliseconds: 350));
    }
  });

  testWidgets('viewed original is reused after closing and reopening', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.view.padding = const FakeViewPadding(top: 24);
    addTearDown(tester.view.resetPadding);
    await pumpImages(tester, [imageMessage('remember')], dark: false);
    await openImage(tester, 'remember');
    final qualityWidth = tester
        .getSize(find.widgetWithText(TextButton, '原图'))
        .width;
    await tester.tap(find.text('原图'));
    await tester.pump();
    final full = find.byWidgetPredicate(
      (widget) =>
          widget is CachedNetworkImage &&
          widget.imageUrl.contains('/original/'),
    );
    expect(full, findsOneWidget);
    final image = tester.widget<CachedNetworkImage>(full);
    image.imageBuilder!(tester.element(full), MemoryImage(pixel));
    await tester.pump();
    await tester.pump();
    expect(find.text('高清'), findsOneWidget);
    expect(
      tester.getSize(find.widgetWithText(TextButton, '高清')).width,
      qualityWidth,
    );
    expect(qualityWidth, lessThanOrEqualTo(56));
    expect(find.text('转发'), findsNothing);
    expect(find.text('转到消息'), findsNothing);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    await openImage(tester, 'remember');
    expect(full, findsWidgets);
    expect(find.text('原图'), findsNothing);
    expect(api.originals, ['mxc://example.org/remember']);
  });

  testWidgets('small image loads original despite large pixel dimensions', (
    tester,
  ) async {
    await pumpImages(tester, [imageMessage('small', size: 512 * 1024)]);
    expect(api.originals, ['mxc://example.org/small']);
    expect(api.thumbnails, isEmpty);
    await openImage(tester, 'small');
    expect(find.byType(TextButton), findsNothing);
    expect(find.byTooltip('下载'), findsOneWidget);
  });

  testWidgets('GIF uses the larger automatic original threshold', (
    tester,
  ) async {
    await pumpImages(tester, [
      imageMessage('gif', size: 4 * 1024 * 1024, filename: 'animation.GIF'),
    ]);
    expect(api.originals, ['mxc://example.org/gif']);
    expect(api.thumbnails, isEmpty);
    await openImage(tester, 'gif');
    expect(find.byType(TextButton), findsNothing);
  });

  testWidgets('swiping selects another image and jump targets that message', (
    tester,
  ) async {
    String? jumped;
    await pumpImages(tester, [
      imageMessage('older'),
      imageMessage('latest'),
    ], onJump: (id) => jumped = id);
    await openImage(tester, 'latest');
    expect(find.byType(PageView), findsOneWidget);
    await tester.drag(find.byType(PageView), const Offset(650, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(
      tester.widget<PageView>(find.byType(PageView)).controller!.page,
      closeTo(0, .01),
    );
    final scrolling = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(PageView),
        matching: find.byType(Scrollable),
      ),
    );
    for (
      var frame = 0;
      frame < 40 && scrolling.position.isScrollingNotifier.value;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump();
    expect(scrolling.position.isScrollingNotifier.value, isFalse);
    await chooseImageAction(tester, 'older', '转到消息');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(jumped, 'older');
    expect(find.byType(InteractiveViewer), findsNothing);
  });
}
