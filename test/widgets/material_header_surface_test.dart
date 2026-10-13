import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/widgets/floating_app_bar.dart';
import 'package:matter/widgets/glass.dart';
import 'package:matter/widgets/material_tab_navigation_bar.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'Linux $brightness header and navigation paint the same translucent surface',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding();
        tester.view.viewPadding = const FakeViewPadding();
        await tester.binding.setSurfaceSize(const Size(320, 240));
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final theme = buildMaterialTheme(brightness)
            .copyWith(platform: TargetPlatform.linux);
        const backdrop = Color(0xFFDC3050);
        final surface = theme.extension<NeuColors>()!.glassFill;
        final position = ValueNotifier(0.0);
        addTearDown(position.dispose);
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: RepaintBoundary(
              key: boundaryKey,
              child: Scaffold(
                extendBody: true,
                extendBodyBehindAppBar: true,
                appBar: buildFloatingAppBar(title: const Text('Title')),
                body: const ColoredBox(
                  color: backdrop,
                  child: SizedBox.expand(),
                ),
                bottomNavigationBar: MaterialTabNavigationBar(
                  position: position,
                  selectedIndex: 0,
                  onDestinationSelected: (_) {},
                  destinations: const [
                    NavigationDestination(icon: Icon(Icons.chat), label: '聊天'),
                    NavigationDestination(
                      icon: Icon(Icons.settings),
                      label: '设置',
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byType(TopFadeBlur)),
          tester.getSize(find.byType(AppBar)),
        );
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final pixels = await tester.runAsync(() async {
          final image = await boundary.toImage();
          try {
            return await image.toByteData(format: ui.ImageByteFormat.rawRgba);
          } finally {
            image.dispose();
          }
        });
        Color sample(int x, int y) {
          final offset = (y * 320 + x) * 4;
          return Color.fromARGB(
            pixels!.getUint8(offset + 3),
            pixels.getUint8(offset),
            pixels.getUint8(offset + 1),
            pixels.getUint8(offset + 2),
          );
        }

        final expected = Color.alphaBlend(surface, backdrop);
        final header = sample(2, kToolbarHeight.toInt() - 4);
        final navigation = sample(2, 236);
        expect(surface.a, greaterThan(0));
        expect(surface.a, lessThan(1));
        for (final actual in [header, navigation]) {
          expect(actual.r, closeTo(expected.r, 1 / 255));
          expect(actual.g, closeTo(expected.g, 1 / 255));
          expect(actual.b, closeTo(expected.b, 1 / 255));
        }
        expect(header, navigation);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
