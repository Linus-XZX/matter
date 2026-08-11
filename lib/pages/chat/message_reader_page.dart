import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../features/matrix_html/matrix_html_renderer.dart';
import '../../theme/app_theme.dart';

/// Opens the full-screen reader for a formatted (markdown) message.
void openMessageReader(
  BuildContext context, {
  required String html,
  required Map<String, String> mentionDisplayNames,
  required ValueChanged<String> onMentionTap,
}) {
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => MessageReaderPage(
        html: html,
        mentionDisplayNames: mentionDisplayNames,
        onMentionTap: onMentionTap,
      ),
    ),
  );
}

/// Full-screen reading view for a formatted message. Reuses the same HTML
/// renderer as the bubble (including table recovery), with a comfortable
/// reading width and selectable text.
class MessageReaderPage extends StatelessWidget {
  final String html;
  final Map<String, String> mentionDisplayNames;
  final ValueChanged<String>? onMentionTap;

  const MessageReaderPage({
    super.key,
    required this.html,
    this.mentionDisplayNames = const {},
    this.onMentionTap,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('阅读'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: MatrixHtmlMessage(
                html: html,
                style: const TextStyle(
                  color: AppColors.onBackground,
                  fontSize: 16,
                  height: 1.5,
                ),
                accentColor: AppColors.secondary,
                mentionDisplayNames: mentionDisplayNames,
                onMentionTap: onMentionTap,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Clips content to [maxCollapsedHeight] when it overflows and shows an
/// "展开阅读" affordance that opens the full-screen reader. Short content
/// renders untouched, so the button only appears on messages that
/// actually benefit from full-screen reading.
///
/// [child] is the normal rendering (with trailing metadata). When the
/// content overflows, [overflowChild] — the same content *without* the
/// metadata — is clipped instead, and [overflowMetadata] is shown once in
/// an overlay row at the bottom of the clip, so the metadata is never
/// mounted (or half-clipped) twice.
///
/// The overlay is a non-positioned Stack child, so it participates in the
/// width calculation (narrow bubbles grow to fit it) while the pinned
/// clip height never changes after the first frame. The overflow state
/// latches, and re-evaluates whenever the content or the layout
/// conditions (window width, text scale) change.
class CollapsibleMessageContent extends StatefulWidget {
  final Widget child;
  final Widget? overflowChild;
  final Widget? overflowMetadata;

  /// Identifies the content being measured; when it changes (e.g. the
  /// message was edited), the collapse state is re-evaluated.
  final Object? contentKey;
  final double maxCollapsedHeight;
  final Color accentColor;

  /// Bubble background color, used to fade out the clipped text under the
  /// overlay row.
  final Color backgroundColor;
  final VoidCallback onExpand;

  const CollapsibleMessageContent({
    super.key,
    required this.child,
    this.overflowChild,
    this.overflowMetadata,
    this.contentKey,
    required this.maxCollapsedHeight,
    required this.accentColor,
    required this.backgroundColor,
    required this.onExpand,
  });

  @override
  State<CollapsibleMessageContent> createState() =>
      _CollapsibleMessageContentState();
}

class _CollapsibleMessageContentState extends State<CollapsibleMessageContent> {
  bool _overflowing = false;
  Object? _layoutSignature;

  void _onOverflowChanged(bool overflowing) {
    // Latch only towards overflow. While collapsed, the shorter
    // overflowChild is measured, and un-latching here would oscillate
    // between the two contents around the threshold. Re-measurement after
    // layout changes is driven by the signature check in build().
    if (mounted && overflowing && !_overflowing) {
      setState(() => _overflowing = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final layoutSignature = Object.hash(
          widget.contentKey,
          // The actual width available to the bubble: window resizes change
          // it, but so do parent-only layout shifts (e.g. a details sidebar
          // closing widens the chat area at the same window width), which
          // the MediaQuery width alone would miss.
          constraints.maxWidth,
          MediaQuery.textScalerOf(context).scale(1),
        );
        if (_layoutSignature != null && _layoutSignature != layoutSignature) {
          // New content or new layout conditions: measure again. Clipping
          // caps the height either way, so this reset cannot flash
          // unclipped content.
          _overflowing = false;
        }
        _layoutSignature = layoutSignature;

        return Stack(
          fit: StackFit.loose,
          alignment: Alignment.bottomLeft,
          children: [
            _ClippedHeight(
              maxHeight: widget.maxCollapsedHeight,
              pinned: _overflowing,
              onOverflowChanged: _onOverflowChanged,
              child: _overflowing
                  ? (widget.overflowChild ?? widget.child)
                  : widget.child,
            ),
            if (_overflowing)
              Align(
                alignment: Alignment.bottomLeft,
                widthFactor: 1,
                heightFactor: 1,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        widget.backgroundColor.withValues(alpha: 0),
                        widget.backgroundColor,
                      ],
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(8, 12, 2, 3),
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.end,
                    spacing: 8,
                    children: [
                      ?widget.overflowMetadata,
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: widget.onExpand,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.unfold_more_rounded,
                              size: 16,
                              color: widget.accentColor,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '展开阅读',
                              style: TextStyle(
                                color: widget.accentColor,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Lays out its child with an unbounded height, then sizes itself to at
/// most [maxHeight] and clips — all within the same layout pass, so a
/// long message never flashes at full height before collapsing. The
/// overflow state is reported via [onOverflowChanged] after the frame.
///
/// When [pinned] (the collapsed state), the height stays exactly
/// [maxHeight] even if a shorter child is swapped in, so the widget never
/// shrinks after the first frame. Clipped-away content is also removed
/// from the semantics tree via [describeApproximatePaintClip].
class _ClippedHeight extends SingleChildRenderObjectWidget {
  final double maxHeight;
  final bool pinned;
  final ValueChanged<bool> onOverflowChanged;

  const _ClippedHeight({
    required this.maxHeight,
    required this.pinned,
    required this.onOverflowChanged,
    required super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _ClippedHeightRenderBox(
        maxHeight: maxHeight,
        pinned: pinned,
        onOverflowChanged: onOverflowChanged,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _ClippedHeightRenderBox renderObject,
  ) {
    renderObject
      ..maxHeight = maxHeight
      ..pinned = pinned
      ..onOverflowChanged = onOverflowChanged;
  }
}

class _ClippedHeightRenderBox extends RenderProxyBox {
  _ClippedHeightRenderBox({
    required this._maxHeight,
    required this._pinned,
    required this.onOverflowChanged,
  });

  double _maxHeight;

  double get maxHeight => _maxHeight;

  set maxHeight(double value) {
    if (_maxHeight == value) return;
    _maxHeight = value;
    markNeedsLayout();
  }

  bool _pinned;

  bool get pinned => _pinned;

  set pinned(bool value) {
    if (_pinned == value) return;
    _pinned = value;
    markNeedsLayout();
  }

  ValueChanged<bool> onOverflowChanged;

  bool _overflowing = false;

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(
      BoxConstraints(
        minWidth: constraints.minWidth,
        maxWidth: constraints.maxWidth,
      ),
      parentUsesSize: true,
    );
    final childSize = child.size;
    size = constraints.constrain(
      Size(
        childSize.width,
        _pinned ? _maxHeight : math.min(childSize.height, _maxHeight),
      ),
    );
    final overflowing = childSize.height > _maxHeight + 1;
    if (overflowing != _overflowing) {
      _overflowing = overflowing;
      markNeedsSemanticsUpdate();
    }
    // Report after every layout, not just on changes: the collapsible
    // latches the overflow state per content key and needs a fresh report
    // after a reset, even when the value is unchanged.
    final callback = onOverflowChanged;
    WidgetsBinding.instance.addPostFrameCallback((_) => callback(overflowing));
  }

  @override
  Rect? describeApproximatePaintClip(RenderObject child) {
    // Reporting the paint clip makes the semantics system clip each child
    // node's rect to the visible region; nodes that fall entirely below the
    // clip end up with an empty rect and are dropped from the compiled
    // semantics tree, so clipped-away links and actions stay unreachable
    // for screen readers.
    return _overflowing ? Offset.zero & size : null;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_overflowing) {
      context.pushClipRect(
        needsCompositing,
        offset,
        Offset.zero & size,
        super.paint,
      );
    } else {
      super.paint(context, offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position)) return false;
    return super.hitTestChildren(result, position: position);
  }
}
