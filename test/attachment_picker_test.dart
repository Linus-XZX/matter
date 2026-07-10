import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/attachment_picker.dart';
import 'package:matter/pages/chat/chat_image_editor_page.dart';
import 'package:matter/pages/chat/latest_message_control.dart';
import 'package:matter/pages/chat/message_input.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

const _pmChannel = 'com.fluttercandies/photo_manager';

Future<void> _mockPhotoManagerEmpty() async {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel(_pmChannel), (call) async {
        switch (call.method) {
          case 'requestPermissionExtend':
            return 3; // PermissionState.authorized
          case 'getAssetPathList':
            return <Map<String, dynamic>>[]; // no albums
          case 'getAssetCountFromPath':
            return 0;
          default:
            return null;
        }
      });
}

void main() {
  test('attachment MIME fallback classifies common image and video files', () {
    final movMime = resolveAttachmentMime(
      'clip.MOV',
      'application/octet-stream',
    );
    final heicMime = resolveAttachmentMime('photo.HEIC', null);

    expect(movMime, 'video/quicktime');
    expect(classifyAttachmentMime(movMime), AttachmentMediaKind.video);
    expect(heicMime, 'image/heic');
    expect(classifyAttachmentMime(heicMime), AttachmentMediaKind.image);
    expect(classifyAttachmentMime('application/pdf'), AttachmentMediaKind.file);
  });

  test('edited image bytes determine their actual MIME type', () {
    expect(
      detectImageMime(Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0])),
      'image/jpeg',
    );
    expect(
      detectImageMime(
        Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
      ),
      'image/png',
    );
    expect(
      detectImageMime(Uint8List.fromList('GIF89a'.codeUnits)),
      'image/gif',
    );
  });

  test('image editor keeps the original file and unbounded output config', () {
    const page = ChatImageEditorPage(
      imagePath: '/original/photo.png',
      mimeType: 'image/png',
    );
    final config = page.imageGenerationConfigs;

    expect(page.imagePath, '/original/photo.png');
    expect(config.enableUseOriginalBytes, isTrue);
    expect(config.maxOutputSize, Size.infinite);
    expect(config.outputFormat, OutputFormat.png);
    expect(config.jpegQuality, 100);
  });

  test(
    'coordinates are validated and normalized without exponent notation',
    () {
      expect(canonicalGeoUri('39.9000', '+116.400000'), 'geo:39.9,116.4');
      expect(canonicalGeoUri('-0', '.5'), 'geo:0,0.5');
      expect(canonicalGeoUri('NaN', '116.4'), isNull);
      expect(canonicalGeoUri('1e-7', '116.4'), isNull);
    },
  );

  testWidgets('plus button opens the attachment picker (no mandatory editor)', (
    tester,
  ) async {
    await _mockPhotoManagerEmpty();
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: _MessageInputHarness())),
    );
    await tester.pump();

    // The attachment affordance is now a plus icon, not a paperclip.
    expect(find.byIcon(Icons.attach_file_rounded), findsNothing);
    final plus = find.byIcon(Icons.add_rounded);
    expect(plus, findsOneWidget);

    await tester.tap(plus);
    await tester.pumpAndSettle();

    // The full-screen picker (with the floating frosted mode bar) is shown.
    expect(find.byType(AttachmentPicker), findsOneWidget);
    expect(find.text('图片'), findsOneWidget);
    expect(find.text('文件'), findsOneWidget);
    expect(find.text('投票'), findsOneWidget);
    expect(find.text('地址'), findsOneWidget);
  });

  testWidgets('location tab disables send until a valid coordinate is set', (
    tester,
  ) async {
    await _mockPhotoManagerEmpty();
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: _MessageInputHarness())),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle();

    // Switch to the location tab.
    await tester.tap(find.text('地址'));
    await tester.pumpAndSettle();

    final sendBtn = find.byType(FilledButton);
    // Empty coordinates => disabled (onPressed null).
    expect(tester.widget<FilledButton>(sendBtn).onPressed, isNull);

    // Enter an out-of-range latitude: still disabled.
    await tester.enterText(find.widgetWithText(TextField, '纬度'), '999');
    await tester.enterText(find.widgetWithText(TextField, '经度'), '116.4');
    await tester.pump();
    expect(tester.widget<FilledButton>(sendBtn).onPressed, isNull);

    // Non-finite and exponent forms are not valid RFC 5870 coordinates.
    await tester.enterText(find.widgetWithText(TextField, '纬度'), 'NaN');
    await tester.pump();
    expect(tester.widget<FilledButton>(sendBtn).onPressed, isNull);
    await tester.enterText(find.widgetWithText(TextField, '纬度'), '1e-7');
    await tester.pump();
    expect(tester.widget<FilledButton>(sendBtn).onPressed, isNull);

    // Valid coordinates => enabled.
    await tester.enterText(find.widgetWithText(TextField, '纬度'), '39.9');
    await tester.pump();
    expect(tester.widget<FilledButton>(sendBtn).onPressed, isNotNull);
  });

  testWidgets('poll requires two answers and tab state is preserved', (
    tester,
  ) async {
    await _mockPhotoManagerEmpty();
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: _MessageInputHarness())),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('投票'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, '问题'), '午饭吃什么？');
    await tester.enterText(find.widgetWithText(TextField, '选项 1'), '面条');
    await tester.pump();
    var sendButton = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(sendButton.onPressed, isNull);

    await tester.enterText(find.widgetWithText(TextField, '选项 2'), '米饭');
    await tester.pump();
    sendButton = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(sendButton.onPressed, isNotNull);

    await tester.tap(find.text('地址'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '纬度'), '39.9');
    await tester.tap(find.text('投票'));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '问题'))
          .controller
          ?.text,
      '午饭吃什么？',
    );
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '选项 1'))
          .controller
          ?.text,
      '面条',
    );
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '选项 2'))
          .controller
          ?.text,
      '米饭',
    );
  });
}

class _MessageInputHarness extends StatefulWidget {
  const _MessageInputHarness();

  @override
  State<_MessageInputHarness> createState() => _MessageInputHarnessState();
}

class _MessageInputHarnessState extends State<_MessageInputHarness> {
  InputPanelMode _panelMode = InputPanelMode.keyboard;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: MessageInput(
          roomId: '!room:example.org',
          totalMembers: 2,
          panelMode: _panelMode,
          pickerHeight: 0,
          pickerFullHeight: 300,
          pickerBaseHeight: 300,
          pickerMaxHeight: 500,
          animatePickerHeight: false,
          onPanelModeChanged: (mode) => setState(() => _panelMode = mode),
          onPickerHeightChanged: (_) {},
          resolveSendPresentation: () => MessageSendPresentation.quiet,
          onMessageQueued: (_, _) {},
          onMessageSent: (_, _) {},
        ),
      ),
    );
  }
}
