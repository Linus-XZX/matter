import 'dart:math' as math;
import 'dart:ui';

class ImageStackLayer {
  final Rect rect;
  final Rect paintBounds;
  final double rotation;
  final double opacity;

  const ImageStackLayer({
    required this.rect,
    required this.paintBounds,
    required this.rotation,
    required this.opacity,
  });
}

class ImageStackLayout {
  final Size size;
  final double scale;
  final List<ImageStackLayer> layers;

  const ImageStackLayout(this.size, this.scale, this.layers);
}

/// The "交错照片" defaults in design/image-stack-playground.html. Fit the
/// complete rotated footprint, then scale every distance together.
ImageStackLayout imageStackLayout(int count, double maxWidth) {
  const photo = Size(270, 180);
  final layers = <ImageStackLayer>[];
  var bounds = Offset.zero & photo;
  for (var depth = 0; depth < math.min(count, 3); depth++) {
    final direction = depth.isOdd ? 1 : -1;
    final scale = math.pow(.98, depth).toDouble();
    final rotation = 5 * depth * direction * math.pi / 180;
    final center = Offset(135 + 13.0 * depth * direction, 90 - 10.0 * depth);
    final size = photo * scale;
    final cosine = math.cos(rotation).abs();
    final sine = math.sin(rotation).abs();
    final halfWidth = cosine * size.width / 2 + sine * size.height / 2;
    final halfHeight = sine * size.width / 2 + cosine * size.height / 2;
    final paintBounds = Rect.fromCenter(
      center: center,
      width: halfWidth * 2,
      height: halfHeight * 2,
    );
    bounds = bounds.expandToInclude(paintBounds);
    layers.add(
      ImageStackLayer(
        rect: Rect.fromCenter(
          center: center,
          width: size.width,
          height: size.height,
        ),
        paintBounds: paintBounds,
        rotation: rotation,
        opacity: math.pow(.97, depth).toDouble(),
      ),
    );
  }
  final scale = math.min(1.0, maxWidth / bounds.width);
  Rect fitted(Rect rect) => Rect.fromLTWH(
    (rect.left - bounds.left) * scale,
    (rect.top - bounds.top) * scale,
    rect.width * scale,
    rect.height * scale,
  );
  return ImageStackLayout(bounds.size * scale, scale, [
    for (final layer in layers)
      ImageStackLayer(
        rect: fitted(layer.rect),
        paintBounds: fitted(layer.paintBounds),
        rotation: layer.rotation,
        opacity: layer.opacity,
      ),
  ]);
}
