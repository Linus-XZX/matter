import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../providers/auth_provider.dart';
import 'media_preparation.dart';
import '../../theme/neu_colors.dart';
import 'chat_media_source.dart';
import 'prepared_media_source.dart';
import 'media_playback.dart';
import 'media_progress_bar.dart';
import 'message_group.dart' show enabledNeuBubbleShadows;

class VideoMessageBubble extends ConsumerStatefulWidget {
  final String? videoUrl;
  final String? mediaSourceJson;
  final String filename;
  final int? videoWidth;
  final int? videoHeight;
  final bool isMe;
  final Object heroTag;
  final Widget metadata;
  final VoidCallback? onLoaded;

  const VideoMessageBubble({
    super.key,
    this.videoUrl,
    this.mediaSourceJson,
    required this.filename,
    this.videoWidth,
    this.videoHeight,
    required this.isMe,
    required this.heroTag,
    required this.metadata,
    this.onLoaded,
  });

  @override
  ConsumerState<VideoMessageBubble> createState() => _VideoMessageBubbleState();
}

class _VideoMessageBubbleState extends ConsumerState<VideoMessageBubble> {
  MediaPlayback? _controller;
  VideoController? _videoController;
  PreparedMediaSource? _preparedSource;
  Object? _error;
  int _initializationId = 0;
  double _previewVolume = 0;
  MediaPreparation? _preparation;
  Route<void>? _previewRoute;

  @override
  void initState() {
    super.initState();
    ref.listenManual(
      currentUserProvider.select((user) => (user?.id, user?.homeserver)),
      (previous, next) => _accountChanged(),
    );
    ref.listenManual(sessionReadyProvider, (previous, next) {
      if (previous == true && !next) _accountChanged();
    });
    _initialize();
  }

  @override
  void didUpdateWidget(covariant VideoMessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoUrl != widget.videoUrl ||
        oldWidget.mediaSourceJson != widget.mediaSourceJson) {
      _initialize();
    }
  }

  void _accountChanged() {
    _initializationId++;
    _preparation?.cancel();
    _closePreview();
    final controller = _controller;
    final source = _preparedSource;
    _controller = null;
    _videoController = null;
    _preparedSource = null;
    unawaited(_disposeVideoSource(controller, source));
    if (mounted) setState(() => _error = StateError('Media account changed'));
  }

  void _closePreview() {
    final route = _previewRoute;
    _previewRoute = null;
    if (route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        route.navigator?.removeRoute(route);
      });
    }
  }

  Future<void> _initialize() async {
    final initializationId = ++_initializationId;
    _preparation?.cancel();
    _closePreview();
    final preparation = _preparation = MediaPreparation();
    final oldController = _controller;
    final oldPreparedSource = _preparedSource;
    final videoUrl = widget.videoUrl;
    final mediaSourceJson = widget.mediaSourceJson;
    final filename = widget.filename;
    _controller = null;
    _videoController = null;
    _preparedSource = null;
    _error = null;
    await _disposeVideoSource(oldController, oldPreparedSource);
    if (!mounted || initializationId != _initializationId) return;

    MediaPlayback? controller;
    PreparedMediaSource? preparedSource;
    try {
      preparedSource = await prepareChatMediaSource(
        ref: ref,
        url: videoUrl,
        mediaSourceJson: mediaSourceJson,
        filename: filename,
        preparation: preparation,
      );
      if (!mounted || initializationId != _initializationId) {
        await preparedSource.cleanup();
        return;
      }
      controller = MediaPlayback();
      final videoController = VideoController(controller.player);
      await videoController.platform.future;
      await controller.setVolume(0);
      await controller.open(preparedSource.media);
      if (!mounted || initializationId != _initializationId) {
        await _disposeVideoSource(controller, preparedSource);
        return;
      }
      setState(() {
        _preparedSource = preparedSource;
        _controller = controller;
        _videoController = videoController;
      });
      widget.onLoaded?.call();
    } catch (error) {
      await _disposeVideoSource(controller, preparedSource);
      if (mounted && initializationId == _initializationId) {
        setState(() => _error = error);
      }
    }
  }

  @override
  void dispose() {
    _initializationId++;
    _preparation?.cancel();
    _closePreview();
    final controller = _controller;
    final preparedSource = _preparedSource;
    _controller = null;
    _preparedSource = null;
    unawaited(_disposeVideoSource(controller, preparedSource));
    super.dispose();
  }

  Future<void> _disposeVideoSource(
    MediaPlayback? controller,
    PreparedMediaSource? preparedSource,
  ) async {
    try {
      await controller?.close();
    } finally {
      await preparedSource?.cleanup();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return ListenableBuilder(
      listenable: controller ?? const AlwaysStoppedAnimation(0),
      builder: (context, child) {
        final size = _bubbleSize(
          context,
          controller?.player.state.width == null
              ? null
              : controller?.aspectRatio,
        );
        final colors = context.neu;
        return Container(
          width: size.width,
          height: size.height,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: widget.isMe
                ? colors.accent.withValues(alpha: 0.3)
                : colors.card,
            borderRadius: BorderRadius.circular(NeuRadius.button),
            boxShadow: enabledNeuBubbleShadows(context, colors),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: controller == null
                    ? _buildPlaceholder(_error != null)
                    : controller.error != null
                    ? _buildPlaceholder(true)
                    : _buildPlayer(context, controller),
              ),
              widget.metadata,
            ],
          ),
        );
      },
    );
  }

  Widget _buildPlayer(BuildContext context, MediaPlayback controller) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Positioned.fill(
          child: Hero(
            tag: widget.heroTag,
            createRectTween: (begin, end) => RectTween(begin: begin, end: end),
            child: _VideoHeroSurface(
              videoController: _videoController!,
              fit: BoxFit.contain,
              borderRadius: BorderRadius.circular(NeuRadius.button),
              showPlayButton: !controller.isPlaying,
            ),
          ),
        ),
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openPreview(context, controller),
          ),
        ),
        if (!controller.isPlaying)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: controller.play,
            child: const SizedBox.square(dimension: 72),
          ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 3,
          child: MediaProgressBar(controller: controller),
        ),
      ],
    );
  }

  Widget _buildPlaceholder(bool failed) {
    return GestureDetector(
      onTap: failed
          ? () {
              setState(() => _error = null);
              unawaited(_initialize());
            }
          : null,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (failed)
              const Icon(Icons.videocam_off_rounded, color: Colors.white70)
            else
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            const SizedBox(height: 8),
            Text(
              failed ? '无法播放此视频' : '正在加载视频…',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openPreview(
    BuildContext context,
    MediaPlayback controller,
  ) async {
    await controller.setVolume(_previewVolume);
    if (!context.mounted || !identical(_controller, controller)) return;
    final videoController = _videoController!;
    final route = _previewRoute = PageRouteBuilder<void>(
      opaque: false,
      transitionDuration: const Duration(milliseconds: 320),
      reverseTransitionDuration: const Duration(milliseconds: 280),
      pageBuilder: (context, animation, secondaryAnimation) => _FullscreenVideo(
        controller: controller,
        videoController: videoController,
        heroTag: widget.heroTag,
        routeAnimation: animation,
      ),
    );
    await Navigator.of(context, rootNavigator: true).push(route);
    if (identical(_previewRoute, route)) _previewRoute = null;
    final previewVolume = controller.volume;
    if (mounted && identical(_controller, controller)) {
      _previewVolume = previewVolume;
      await controller.setVolume(0);
    }
  }

  Size _bubbleSize(BuildContext context, double? playerAspectRatio) {
    const maxHeight = 320.0;
    final maxWidth = (MediaQuery.sizeOf(context).width * 0.68).clamp(
      180.0,
      360.0,
    );
    final metadataWidth = widget.videoWidth?.toDouble();
    final metadataHeight = widget.videoHeight?.toDouble();
    final metadataAspectRatio =
        metadataWidth != null &&
            metadataHeight != null &&
            metadataWidth > 0 &&
            metadataHeight > 0
        ? metadataWidth / metadataHeight
        : 16 / 9;
    final aspectRatio =
        playerAspectRatio != null &&
            playerAspectRatio.isFinite &&
            playerAspectRatio > 0
        ? playerAspectRatio
        : metadataAspectRatio;

    var width = maxWidth;
    var height = width / aspectRatio;
    if (height > maxHeight) {
      height = maxHeight;
      width = height * aspectRatio;
    }
    return Size(width, height);
  }
}

class _VideoHeroSurface extends StatelessWidget {
  final VideoController videoController;
  final BoxFit fit;
  final BorderRadius borderRadius;
  final bool showPlayButton;

  const _VideoHeroSurface({
    required this.videoController,
    required this.fit,
    required this.borderRadius,
    required this.showPlayButton,
  });

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: borderRadius,
    child: Stack(
      fit: StackFit.expand,
      alignment: Alignment.center,
      children: [
        Video(controller: videoController, fit: fit, controls: NoVideoControls),
        if (showPlayButton) const Center(child: _PlayButton()),
      ],
    ),
  );
}

class _PlayButton extends StatelessWidget {
  const _PlayButton();

  @override
  Widget build(BuildContext context) => Container(
    width: 52,
    height: 52,
    decoration: const BoxDecoration(
      color: Colors.black54,
      shape: BoxShape.circle,
    ),
    child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 34),
  );
}

class _FullscreenVideo extends StatefulWidget {
  final MediaPlayback controller;
  final VideoController videoController;
  final Object heroTag;
  final Animation<double> routeAnimation;

  const _FullscreenVideo({
    required this.controller,
    required this.videoController,
    required this.heroTag,
    required this.routeAnimation,
  });

  @override
  State<_FullscreenVideo> createState() => _FullscreenVideoState();
}

class _FullscreenVideoState extends State<_FullscreenVideo> {
  bool _isFullscreen = false;
  bool _controlsVisible = true;
  bool _volumePanelVisible = false;
  Timer? _hideControlsTimer;

  @override
  void initState() {
    super.initState();
    _scheduleControlsHide();
  }

  void _scheduleControlsHide() {
    _hideControlsTimer?.cancel();
    if (!widget.controller.isPlaying || _volumePanelVisible) return;
    _hideControlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    setState(() {
      _controlsVisible = !_controlsVisible;
      if (!_controlsVisible) _volumePanelVisible = false;
    });
    if (_controlsVisible) _scheduleControlsHide();
  }

  Future<void> _togglePlayback() async {
    final controller = widget.controller;
    await (controller.isPlaying ? controller.pause() : controller.play());
    if (!mounted) return;
    setState(() => _controlsVisible = true);
    _scheduleControlsHide();
  }

  void _toggleVolumePanel() {
    setState(() {
      _controlsVisible = true;
      _volumePanelVisible = !_volumePanelVisible;
    });
    _scheduleControlsHide();
  }

  Future<void> _toggleFullscreen() async {
    if (_isFullscreen) {
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      if (mounted) setState(() => _isFullscreen = false);
    } else {
      final isLandscape = widget.controller.aspectRatio >= 1;
      await SystemChrome.setPreferredOrientations(
        isLandscape
            ? const [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]
            : const [DeviceOrientation.portraitUp],
      );
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      if (mounted) setState(() => _isFullscreen = true);
    }
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    if (_isFullscreen) {
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, child) {
      final value = widget.controller;
      return AnimatedBuilder(
        animation: widget.routeAnimation,
        builder: (context, child) => Material(
          type: MaterialType.transparency,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black.withValues(
                    alpha: Curves.easeOut.transform(
                      widget.routeAnimation.value,
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleControls,
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: value.aspectRatio,
                      child: Hero(
                        tag: widget.heroTag,
                        createRectTween: (begin, end) =>
                            RectTween(begin: begin, end: end),
                        child: _VideoHeroSurface(
                          videoController: widget.videoController,
                          fit: BoxFit.contain,
                          borderRadius: BorderRadius.zero,
                          showPlayButton: !value.isPlaying,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (!value.isPlaying)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _togglePlayback,
                  child: const SizedBox.square(dimension: 76),
                ),
              Positioned(
                top: MediaQuery.paddingOf(context).top,
                left: 4,
                child: AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      color: Colors.white,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 16,
                bottom: MediaQuery.paddingOf(context).bottom + 92,
                child: AnimatedScale(
                  scale: _volumePanelVisible ? 1 : 0.92,
                  duration: const Duration(milliseconds: 160),
                  child: AnimatedOpacity(
                    opacity: _volumePanelVisible ? 1 : 0,
                    duration: const Duration(milliseconds: 160),
                    child: IgnorePointer(
                      ignoring: !_volumePanelVisible,
                      child: _VolumePanel(
                        value: value.volume,
                        onChanged: widget.controller.setVolume,
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 16,
                right: 16,
                bottom: MediaQuery.paddingOf(context).bottom + 16,
                child: AnimatedSlide(
                  offset: _controlsVisible ? Offset.zero : const Offset(0, 0.3),
                  duration: const Duration(milliseconds: 180),
                  child: AnimatedOpacity(
                    opacity: _controlsVisible ? 1 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: IgnorePointer(
                      ignoring: !_controlsVisible,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.58),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: MediaProgressBar(
                                controller: widget.controller,
                                allowScrubbing: true,
                              ),
                            ),
                            Row(
                              children: [
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  tooltip: value.isPlaying ? '暂停' : '播放',
                                  color: Colors.white,
                                  onPressed: _togglePlayback,
                                  icon: Icon(
                                    value.isPlaying
                                        ? Icons.pause_rounded
                                        : Icons.play_arrow_rounded,
                                  ),
                                ),
                                Text(
                                  '${_formatDuration(value.position)} / '
                                  '${_formatDuration(value.duration)}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontFeatures: [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                                const Spacer(),
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  tooltip: '音量',
                                  color: Colors.white,
                                  onPressed: _toggleVolumePanel,
                                  icon: Icon(_volumeIcon(value.volume)),
                                ),
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  tooltip: _isFullscreen ? '退出全屏' : '全屏播放',
                                  color: Colors.white,
                                  onPressed: _toggleFullscreen,
                                  icon: Icon(
                                    _isFullscreen
                                        ? Icons.fullscreen_exit_rounded
                                        : Icons.fullscreen_rounded,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _VolumePanel extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;

  const _VolumePanel({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: Container(
      width: 210,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: value == 0 ? '恢复声音' : '静音',
            color: Colors.white,
            onPressed: () => onChanged(value == 0 ? 1 : 0),
            icon: Icon(_volumeIcon(value), size: 21),
          ),
          Expanded(
            child: Slider(value: value, onChanged: onChanged, min: 0, max: 1),
          ),
        ],
      ),
    ),
  );
}

IconData _volumeIcon(double volume) {
  if (volume == 0) return Icons.volume_off_rounded;
  if (volume < 0.5) return Icons.volume_down_rounded;
  return Icons.volume_up_rounded;
}

String _formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:$minutes:$seconds'
      : '${duration.inMinutes}:$seconds';
}
