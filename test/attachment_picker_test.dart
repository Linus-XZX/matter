import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/attachment_picker.dart';
import 'package:matter/pages/chat/latest_message_control.dart';
import 'package:matter/pages/chat/message_input.dart';

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
  testWidgets('plus button opens the attachment picker (no mandatory editor)',
      (tester) async {
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
