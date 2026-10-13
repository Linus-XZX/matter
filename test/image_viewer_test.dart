import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/image_viewer.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/providers/message_cache_persistence.dart';
import 'package:matter/pages/chat/message_group.dart';
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
  ImageHistoryLoader? loadOlder,
  String account = 'image-tester',
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
        theme: neuTestTheme(),
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
        of: find.byKey(const ValueKey('older')),
        matching: find.byTooltip('下载'),
      ),
    );
    await tester.pump();
    expect(api.downloads, ['mxc://example.org/older']);
    expect(suggestedName, 'older.png');
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('older')),
        matching: find.byTooltip('转发'),
      ),
    );
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
      await tester.tap(find.byTooltip('转到该图片').hitTestable());
      await tester.pump();
      expect(jumped, 'older');
    },
  );

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
      expect(find.text('重试原图'), findsOneWidget);
      api.originalPending = null;
      await tester.tap(find.text('重试原图'));
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
    await pumpImages(tester, [imageMessage('remember')]);
    await openImage(tester, 'remember');
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
    expect(find.text('已原图'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close_rounded));
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
  });

  testWidgets('GIF uses the larger automatic original threshold', (
    tester,
  ) async {
    await pumpImages(tester, [
      imageMessage('gif', size: 4 * 1024 * 1024, filename: 'animation.GIF'),
    ]);
    expect(api.originals, ['mxc://example.org/gif']);
    expect(api.thumbnails, isEmpty);
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
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('older')),
        matching: find.byTooltip('转到该图片'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(jumped, 'older');
    expect(find.byType(InteractiveViewer), findsNothing);
  });
}
