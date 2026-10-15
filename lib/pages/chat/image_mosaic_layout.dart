import 'dart:math' as math;

import 'package:flutter/widgets.dart';

class ImageMosaicLayout {
  final List<Rect> tiles;
  final double height;
  const ImageMosaicLayout(this.tiles, this.height);
}

/// Justified rows fill the message width; three-image layouts give the first
/// portrait a tall column or the first landscape a full-width row.
ImageMosaicLayout imageMosaicLayout(List<double> ratios, double width) {
  const gap = 2.0;
  final aspects = ratios
      .map((ratio) => ratio.clamp(.5, 2.0).toDouble())
      .toList();
  if (aspects.isEmpty || width <= 0) return const ImageMosaicLayout([], 0);
  if (aspects.length == 1) {
    final height = (width / aspects.first)
        .clamp(width * .5, width * 1.2)
        .toDouble();
    return ImageMosaicLayout([Rect.fromLTWH(0, 0, width, height)], height);
  }
  final tiles = <Rect>[];
  double top = 0;
  void row(int start, int count, {double? height}) {
    final sum = aspects
        .skip(start)
        .take(count)
        .fold(0.0, (sum, value) => sum + value);
    final available = width - gap * (count - 1);
    final rowHeight = height ?? available / sum;
    double left = 0;
    for (var index = 0; index < count; index++) {
      final tileWidth = index == count - 1
          ? width - left
          : available * aspects[start + index] / sum;
      tiles.add(Rect.fromLTWH(left, top, tileWidth, rowHeight));
      left += tileWidth + gap;
    }
    top += rowHeight + gap;
  }

  if (aspects.length == 3 && aspects.first < 1) {
    final height = width * .9;
    final leftWidth = (width - gap) * .48;
    final rightWidth = width - leftWidth - gap;
    final upperHeight = (height - gap) * aspects[2] / (aspects[1] + aspects[2]);
    return ImageMosaicLayout([
      Rect.fromLTWH(0, 0, leftWidth, height),
      Rect.fromLTWH(leftWidth + gap, 0, rightWidth, upperHeight),
      Rect.fromLTWH(
        leftWidth + gap,
        upperHeight + gap,
        rightWidth,
        height - upperHeight - gap,
      ),
    ], height);
  }
  if (aspects.length == 3) {
    row(
      0,
      1,
      height: (width / aspects.first).clamp(width * .45, width * .7).toDouble(),
    );
    row(1, 2);
  } else {
    var start = 0;
    while (start < aspects.length) {
      final remaining = aspects.length - start;
      final count = remaining <= 3
          ? remaining
          : remaining == 4 ||
                aspects.skip(start).take(3).any((ratio) => ratio < .8)
          ? 2
          : 3;
      row(start, math.min(count, remaining));
      start += count;
    }
  }
  return ImageMosaicLayout(tiles, top - gap);
}
