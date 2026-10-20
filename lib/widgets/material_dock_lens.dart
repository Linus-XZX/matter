import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Paints one destination through the dock's lens. The same child supplies both
/// passes, so text, hit testing and semantics still have a single layout.
class DockLensContents extends SingleChildRenderObjectWidget {
  const DockLensContents({
    super.key,
    required this.lens,
    required this.color,
    required this.magnification,
    required super.child,
  });

  /// The bar's lens translated into this destination's local coordinates.
  final RRect lens;
  final Color color;
  final double magnification;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderLensContents(
    lens: lens,
    color: color,
    magnification: magnification,
  );

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderLensContents).update(lens, color, magnification);
  }
}

class _RenderLensContents extends RenderProxyBox {
  _RenderLensContents({
    required this._lens,
    required this._color,
    required this._magnification,
  });

  RRect _lens;
  Color _color;
  double _magnification;
  final _outside = LayerHandle<ClipPathLayer>();
  final _inside = LayerHandle<ClipRRectLayer>();
  final _tint = LayerHandle<ColorFilterLayer>();
  final _magnified = LayerHandle<TransformLayer>();

  void update(RRect lens, Color color, double magnification) {
    if (_lens == lens && _color == color && _magnification == magnification) {
      return;
    }
    _lens = lens;
    _color = color;
    _magnification = magnification;
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => child != null;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    final bounds = Offset.zero & size;
    // The outside pass stays neutral, including the uncovered part of a glyph
    // whose other half is already under the lens.
    _outside.layer = context.pushClipPath(
      needsCompositing,
      offset,
      bounds,
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(bounds)
        ..addRRect(_lens),
      super.paint,
      oldLayer: _outside.layer,
    );
    _inside.layer = context.pushClipRRect(
      needsCompositing,
      offset,
      bounds,
      _lens,
      (context, offset) {
        _tint.layer = context.pushColorFilter(
          offset,
          ColorFilter.mode(_color, BlendMode.srcIn),
          (context, offset) {
            final center = size.center(Offset.zero);
            final transform =
                Matrix4.diagonal3Values(_magnification, _magnification, 1)
                  ..setTranslationRaw(
                    center.dx * (1 - _magnification),
                    center.dy * (1 - _magnification),
                    0,
                  );
            _magnified.layer = context.pushTransform(
              needsCompositing,
              offset,
              transform,
              super.paint,
              oldLayer: _magnified.layer,
            );
          },
          oldLayer: _tint.layer,
        );
      },
      oldLayer: _inside.layer,
    );
  }

  @override
  void dispose() {
    _outside.layer = null;
    _inside.layer = null;
    _tint.layer = null;
    _magnified.layer = null;
    super.dispose();
  }
}
