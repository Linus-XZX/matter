import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/widgets/neu_decoration.dart';

class _RecordingCanvas implements Canvas {
  final paths = <Path>[];

  @override
  void drawPath(Path path, Paint paint) => paths.add(path);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<List<int>> _pixels(BoxPainter painter, Size size, Offset offset) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), offset, ImageConfiguration(size: size));
  final picture = recorder.endRecording();
  final image = await picture.toImage(240, 160);
  final data = await image.toByteData();
  final bytes = data!.buffer.asUint8List().toList();
  image.dispose();
  picture.dispose();
  return bytes;
}

void main() {
  test('shadow decorations advertise raster-cache complexity', () {
    for (final depth in NeuDepth.values) {
      expect(
        NeuDecoration(colors: NeuColors.light, depth: depth).isComplex,
        depth != NeuDepth.flat,
      );
    }
  });

  for (final depth in NeuDepth.values) {
    test('$depth reuses geometry when only paint offset changes', () {
      final painter = NeuDecoration(
        colors: NeuColors.light,
        depth: depth,
      ).createBoxPainter();
      final first = _RecordingCanvas();
      final second = _RecordingCanvas();
      const configuration = ImageConfiguration(size: Size(120, 60));
      painter.paint(first, Offset.zero, configuration);
      painter.paint(second, const Offset(20, 30), configuration);
      expect(first.paths, isNotEmpty);
      expect(second.paths.length, first.paths.length);
      for (var i = 0; i < first.paths.length; i++) {
        expect(identical(first.paths[i], second.paths[i]), isTrue);
      }
      painter.dispose();
    });

    testWidgets('$depth cached paint stays correct after moving and resizing', (
      tester,
    ) async {
      await tester.runAsync(() async {
        for (final colors in [NeuColors.light, NeuColors.dark]) {
          final decoration = NeuDecoration(
            colors: colors,
            depth: depth,
            accent: true,
            borderColor: colors.accent,
          );
          final cached = decoration.createBoxPainter();
          await _pixels(cached, const Size(120, 60), const Offset(12, 12));
          for (final size in [const Size(120, 60), const Size(180, 90)]) {
            final fresh = decoration.createBoxPainter();
            expect(
              await _pixels(cached, size, const Offset(25, 30)),
              await _pixels(fresh, size, const Offset(25, 30)),
            );
            fresh.dispose();
          }
          cached.dispose();
        }
      });
    });
  }
}
