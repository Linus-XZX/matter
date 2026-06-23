import 'dart:async';

import 'package:flutter/material.dart';

import '../../providers/chat_provider.dart';
import '../../theme/app_theme.dart';

enum SendFlightKind { text, sticker }

class SendFlightSpec {
  final Rect sourceRect;
  final Widget child;
  final SendFlightKind kind;

  const SendFlightSpec({
    required this.sourceRect,
    required this.child,
    required this.kind,
  });
}

final Map<String, _PendingFlight> _pendingSendFlights = {};
final Map<String, Completer<void>> _activeSendFlights = {};
final ValueNotifier<int> _sendFlightStateRevision = ValueNotifier<int>(0);

class _PendingFlight {
  final SendFlightSpec spec;
  final Completer<void> completer = Completer<void>();

  _PendingFlight(this.spec);
}

String sendFlightId(String messageId) {
  for (final prefix in [
    localOutgoingPendingPrefix,
    localOutgoingSentPrefix,
    localOutgoingFailedPrefix,
  ]) {
    if (messageId.startsWith(prefix)) {
      return messageId.substring(prefix.length);
    }
  }
  return messageId;
}

void _notifySendFlightStateChanged() {
  _sendFlightStateRevision.value++;
}

bool _shouldHideSendFlightTarget(String id) =>
    _pendingSendFlights.containsKey(id) || _activeSendFlights.containsKey(id);

/// Registers a send flight and returns a [Future] that completes when the
/// flight animation finishes (or times out). If a flight for the same message
/// id is already registered, the existing future is returned.
Future<void> registerSendFlight(String messageId, SendFlightSpec spec) {
  final id = sendFlightId(messageId);
  final existing = _pendingSendFlights[id];
  if (existing != null) {
    return existing.completer.future;
  }
  final active = _activeSendFlights[id];
  if (active != null) return active.future;
  final pending = _PendingFlight(spec);
  _pendingSendFlights[id] = pending;
  _notifySendFlightStateChanged();
  unawaited(
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (identical(_pendingSendFlights[id], pending)) {
        _pendingSendFlights.remove(id);
        _notifySendFlightStateChanged();
        if (!pending.completer.isCompleted) pending.completer.complete();
      }
    }),
  );
  return pending.completer.future;
}

class SendFlightTarget extends StatefulWidget {
  final String messageId;
  final String? flightId;
  final Widget child;

  const SendFlightTarget({
    super.key,
    required this.messageId,
    this.flightId,
    required this.child,
  });

  @override
  State<SendFlightTarget> createState() => _SendFlightTargetState();
}

class _SendFlightTargetState extends State<SendFlightTarget> {
  final GlobalKey _targetKey = GlobalKey();
  bool _hideTarget = false;
  String? _scheduledFlightId;

  String get _flightId => widget.flightId ?? sendFlightId(widget.messageId);

  @override
  void initState() {
    super.initState();
    _sendFlightStateRevision.addListener(_handleFlightStateChanged);
    _hideTarget = _shouldHideSendFlightTarget(_flightId);
    _maybeStartFlight(_flightId);
  }

  @override
  void didUpdateWidget(covariant SendFlightTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldId = oldWidget.flightId ?? sendFlightId(oldWidget.messageId);
    final newId = _flightId;
    if (oldId != newId) {
      _scheduledFlightId = null;
    }
    _syncHiddenState();
    _maybeStartFlight(newId);
  }

  @override
  void dispose() {
    _sendFlightStateRevision.removeListener(_handleFlightStateChanged);
    super.dispose();
  }

  void _handleFlightStateChanged() {
    if (!mounted) return;
    _syncHiddenState();
    _maybeStartFlight(_flightId);
  }

  void _syncHiddenState() {
    final shouldHide = _shouldHideSendFlightTarget(_flightId);
    if (_hideTarget == shouldHide) return;
    setState(() => _hideTarget = shouldHide);
  }

  void _maybeStartFlight(String id) {
    if (!_pendingSendFlights.containsKey(id) || _scheduledFlightId == id) {
      return;
    }
    _scheduledFlightId = id;
    WidgetsBinding.instance.addPostFrameCallback((_) => _startFlight(id));
  }

  Future<void> _startFlight(String id) async {
    final pending = _pendingSendFlights.remove(id);
    if (pending != null) {
      _activeSendFlights[id] = pending.completer;
      _notifySendFlightStateChanged();
    }
    if (pending == null || !mounted) {
      if (pending != null && !pending.completer.isCompleted) {
        _activeSendFlights.remove(id);
        _notifySendFlightStateChanged();
        pending.completer.complete();
      }
      return;
    }
    final spec = pending.spec;
    final overlay = Overlay.of(context, rootOverlay: true);
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    if (overlayBox == null || !overlayBox.hasSize) {
      _activeSendFlights.remove(id);
      _notifySendFlightStateChanged();
      if (!pending.completer.isCompleted) pending.completer.complete();
      return;
    }

    Rect inOverlay(Rect rect) => Rect.fromPoints(
      overlayBox.globalToLocal(rect.topLeft),
      overlayBox.globalToLocal(rect.bottomRight),
    );

    Rect? targetRect() {
      final targetBox =
          _targetKey.currentContext?.findRenderObject() as RenderBox?;
      if (targetBox == null || !targetBox.hasSize || !targetBox.attached) {
        return null;
      }
      final topLeft = targetBox.localToGlobal(
        Offset.zero,
        ancestor: overlayBox,
      );
      return topLeft & targetBox.size;
    }

    final end = targetRect() ?? inOverlay(spec.sourceRect);
    final overlayCompleter = Completer<void>();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _SendFlightOverlay(
        spec: spec,
        begin: inOverlay(spec.sourceRect),
        end: end,
        resolveEnd: targetRect,
        onCompleted: () {
          entry.remove();
          if (!overlayCompleter.isCompleted) overlayCompleter.complete();
        },
      ),
    );
    overlay.insert(entry);
    try {
      await overlayCompleter.future;
    } finally {
      _activeSendFlights.remove(id);
      _notifySendFlightStateChanged();
      if (!pending.completer.isCompleted) pending.completer.complete();
    }
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: _targetKey,
      child: Opacity(opacity: _hideTarget ? 0 : 1, child: widget.child),
    );
  }
}

class _SendFlightOverlay extends StatefulWidget {
  final SendFlightSpec spec;
  final Rect begin;
  final Rect end;
  final Rect? Function()? resolveEnd;
  final VoidCallback onCompleted;

  const _SendFlightOverlay({
    required this.spec,
    required this.begin,
    required this.end,
    this.resolveEnd,
    required this.onCompleted,
  });

  @override
  State<_SendFlightOverlay> createState() => _SendFlightOverlayState();
}

class _SendFlightOverlayState extends State<_SendFlightOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(
        milliseconds: widget.spec.kind == SendFlightKind.sticker ? 360 : 300,
      ),
    );
    _animation =
        CurvedAnimation(
          parent: _controller,
          curve: Curves.easeInOutCubicEmphasized,
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed) {
            widget.onCompleted();
          }
        });
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Material(
        type: MaterialType.transparency,
        child: DefaultTextStyle(
          style: const TextStyle(
            color: AppColors.onBackground,
            fontSize: 15,
            fontWeight: FontWeight.w400,
            decoration: TextDecoration.none,
          ),
          child: AnimatedBuilder(
            animation: _animation,
            child: widget.spec.child,
            builder: (context, child) {
              final progress = _animation.value;
              final end = widget.resolveEnd?.call() ?? widget.end;
              final rect = Rect.lerp(widget.begin, end, progress)!;
              final isText = widget.spec.kind == SendFlightKind.text;
              return Stack(
                children: [
                  Positioned.fromRect(
                    rect: rect,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: isText
                            ? Color.lerp(
                                AppColors.surfaceVariant,
                                AppColors.primary,
                                progress,
                              )
                            : Colors.transparent,
                        borderRadius: BorderRadius.lerp(
                          BorderRadius.circular(AppRadii.surface),
                          BorderRadius.circular(AppRadii.content),
                          progress,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadii.content),
                        child: child,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
