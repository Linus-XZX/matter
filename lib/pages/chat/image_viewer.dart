import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/message_ordering.dart';
import '../../src/rust/api/matrix.dart' as rust;
import 'file_download_saver.dart';
import 'file_message_bubble.dart' show sanitizeAttachmentFilename;
import 'forward_message_sheet.dart';
import 'image_loading_policy.dart';
import 'image_media.dart';
import 'image_zoom_frame.dart';

typedef ImageHistoryLoader =
    Future<({List<rust.ChatMessage> messages, bool hasMore})> Function();

class ImageViewerSource {
  final Object heroTag;
  final rust.ChatMessage? message;
  final String? imageUrl;
  final String? mediaSourceJson;
  final String? previewUrl;
  final Uint8List? imageBytes;
  final int? width;
  final int? height;
  final int? fileSize;
  final String? mimeType;
  final String? filename;

  const ImageViewerSource({
    required this.heroTag,
    this.message,
    this.imageUrl,
    this.mediaSourceJson,
    this.previewUrl,
    this.imageBytes,
    this.width,
    this.height,
    this.fileSize,
    this.mimeType,
    this.filename,
  });

  factory ImageViewerSource.fromMessage(rust.ChatMessage message) =>
      ImageViewerSource(
        heroTag: 'image-preview:${message.id}',
        message: message,
        imageUrl: message.imageUrl,
        mediaSourceJson: message.mediaSourceJson,
        width: message.imageWidth,
        height: message.imageHeight,
        fileSize: message.fileSize,
        mimeType: message.mimeType,
        filename: message.filename ?? message.content,
      );

  String get id => message?.id ?? heroTag.toString();
  double get aspectRatio =>
      width != null && height != null && width! > 0 && height! > 0
      ? width! / height!
      : 1;
}

class ChatImageViewer extends ConsumerStatefulWidget {
  final ImageViewerSource initialSource;
  final Iterable<rust.ChatMessage> messages;
  final Animation<double> animation;
  final String? roomId;
  final ValueChanged<String>? onMessageJumpRequested;
  final ValueChanged<rust.ChatRoom>? onMessageForwarded;
  final ImageHistoryLoader? loadOlderImages;

  const ChatImageViewer({
    super.key,
    required this.initialSource,
    required this.animation,
    this.messages = const [],
    this.roomId,
    this.onMessageJumpRequested,
    this.onMessageForwarded,
    this.loadOlderImages,
  });

  @override
  ConsumerState<ChatImageViewer> createState() => _ChatImageViewerState();
}

class _ChatImageViewerState extends ConsumerState<ChatImageViewer> {
  late List<ImageViewerSource> _sources;
  late final PageController _pages;
  late final String? _account;
  late int _index;
  bool _zoomed = false;
  bool _loadingOlder = false;
  late bool _hasMore;

  List<ImageViewerSource> _imageSources(Iterable<rust.ChatMessage> messages) {
    final images =
        messages
            .where(
              (message) =>
                  message.msgType == rust.MessageType.image &&
                  (message.imageUrl != null || message.mediaSourceJson != null),
            )
            .toList()
          ..sort(compareChatMessages);
    return images
        .map(
          (message) => message.id == widget.initialSource.id
              ? widget.initialSource
              : ImageViewerSource.fromMessage(message),
        )
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _account = ref.read(activeUserIdProvider);
    _sources = _imageSources(widget.messages);
    if (!_sources.any((source) => source.id == widget.initialSource.id)) {
      _sources.add(widget.initialSource);
    }
    _index = _sources.indexWhere(
      (source) => source.id == widget.initialSource.id,
    );
    _pages = PageController(initialPage: _index);
    _hasMore = widget.loadOlderImages != null;
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _previous() async {
    if (_loadingOlder || _zoomed) return;
    if (_index > 0) {
      await _pages.previousPage(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
      return;
    }
    final loader = widget.loadOlderImages;
    if (loader == null || !_hasMore) return;
    setState(() => _loadingOlder = true);
    try {
      final currentId = _sources[_index].id;
      final history = await loader();
      if (!mounted || ref.read(activeUserIdProvider) != _account) return;
      final byId = {for (final source in _sources) source.id: source};
      for (final source in _imageSources(history.messages)) {
        byId.putIfAbsent(source.id, () => source);
      }
      final sources = byId.values.toList()
        ..sort((a, b) {
          if (a.message == null || b.message == null) return 0;
          return compareChatMessages(a.message!, b.message!);
        });
      final nextIndex = sources.indexWhere((source) => source.id == currentId);
      setState(() {
        _sources = sources;
        _index = nextIndex;
        _hasMore = history.hasMore;
      });
      _pages.jumpToPage(nextIndex);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      if (nextIndex > 0) {
        await _pages.previousPage(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      } else if (_hasMore) {
        _notify('这页没有图片，可继续加载更早消息');
      }
    } catch (error) {
      if (mounted) _notify('加载更早图片失败: $error');
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  void _notify(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) {
    ref.listen(activeUserIdProvider, (_, next) {
      if (next != _account) Navigator.of(context).pop();
    });
    return AnimatedBuilder(
      animation: widget.animation,
      builder: (context, _) => Scaffold(
        backgroundColor: Colors.black.withValues(
          alpha: Curves.easeOut.transform(widget.animation.value),
        ),
        body: Stack(
          children: [
            DismissibleImageGallery(
              enabled: !_zoomed,
              onClose: () => Navigator.of(context).pop(),
              child: NotificationListener<OverscrollNotification>(
                onNotification: (notification) {
                  if (notification.overscroll < -10 &&
                      notification.dragDetails != null &&
                      _index == 0 &&
                      _hasMore) {
                    unawaited(_previous());
                  }
                  return false;
                },
                child: PageView.builder(
                  controller: _pages,
                  physics: _zoomed
                      ? const NeverScrollableScrollPhysics()
                      : const PageScrollPhysics(),
                  itemCount: _sources.length,
                  findChildIndexCallback: (key) {
                    final index = _sources.indexWhere(
                      (source) => ValueKey(source.id) == key,
                    );
                    return index < 0 ? null : index;
                  },
                  onPageChanged: (index) => setState(() {
                    _index = index;
                    _zoomed = false;
                  }),
                  itemBuilder: (context, index) => _ImageViewerPage(
                    key: ValueKey(_sources[index].id),
                    source: _sources[index],
                    roomId: widget.roomId,
                    active: index == _index,
                    onZoomChanged: (zoomed) {
                      if (index == _index && _zoomed != zoomed) {
                        setState(() => _zoomed = zoomed);
                      }
                    },
                    onMessageJumpRequested: widget.onMessageJumpRequested,
                    onMessageForwarded: widget.onMessageForwarded,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.paddingOf(context).bottom + 12,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: _index == 0 && _hasMore ? '加载更早图片' : '上一张',
                    onPressed:
                        !_zoomed && !_loadingOlder && (_index > 0 || _hasMore)
                        ? _previous
                        : null,
                    icon: _loadingOlder
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(
                            Icons.chevron_left_rounded,
                            color: Colors.white,
                          ),
                  ),
                  Text(
                    '${_index + 1} / ${_sources.length}',
                    style: const TextStyle(color: Colors.white),
                  ),
                  IconButton(
                    tooltip: '下一张',
                    onPressed: !_zoomed && _index < _sources.length - 1
                        ? () => _pages.nextPage(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOut,
                          )
                        : null,
                    icon: const Icon(
                      Icons.chevron_right_rounded,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _OriginalState { thumbnail, resolving, loading, loaded, failed }

class _ImageViewerPage extends ConsumerStatefulWidget {
  final ImageViewerSource source;
  final String? roomId;
  final bool active;
  final ValueChanged<bool> onZoomChanged;
  final ValueChanged<String>? onMessageJumpRequested;
  final ValueChanged<rust.ChatRoom>? onMessageForwarded;

  const _ImageViewerPage({
    super.key,
    required this.source,
    required this.roomId,
    required this.active,
    required this.onZoomChanged,
    this.onMessageJumpRequested,
    this.onMessageForwarded,
  });

  @override
  ConsumerState<_ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends ConsumerState<_ImageViewerPage> {
  late String? _url;
  late Uint8List? _bytes;
  _OriginalState _original = _OriginalState.thumbnail;
  bool _downloading = false;
  bool _forwarding = false;
  bool _resolveFailed = false;

  @override
  void initState() {
    super.initState();
    _url = widget.source.previewUrl;
    _bytes = widget.source.imageBytes;
    _resolveImage();
  }

  Future<void> _resolveImage() async {
    final source = widget.source;
    _resolveFailed = false;
    if (_bytes != null) {
      _original = _OriginalState.loaded;
      return;
    }
    if (source.imageUrl == null && source.mediaSourceJson != null) {
      setState(() => _original = _OriginalState.resolving);
      try {
        final bytes = await rust.downloadMediaSourceBytes(
          mediaSourceJson: source.mediaSourceJson!,
          maxSizeBytes: 64 * 1024 * 1024,
        );
        if (!mounted) return;
        setState(() {
          _bytes = bytes;
          _original = _OriginalState.loading;
        });
      } catch (_) {
        if (mounted) setState(() => _original = _OriginalState.failed);
      }
      return;
    }
    final rawUrl = source.imageUrl;
    if (rawUrl == null) return;
    if (!rawUrl.startsWith('mxc://')) {
      setState(() {
        _url = rawUrl;
        _original = _OriginalState.loading;
      });
      return;
    }
    if (cachedOriginalMxcUrl(ref, rawUrl) != null ||
        shouldAutoLoadOriginal(
          fileSize: source.fileSize,
          mimeType: source.mimeType,
          filename: source.filename,
        )) {
      await _loadOriginal();
      return;
    }
    if (source.previewUrl != null) return;
    final url = await resolveMxcUrl(
      ref,
      rawUrl,
      width: 1600,
      height: 1200,
      useOriginalIfCached: true,
    );
    if (!mounted) return;
    setState(() {
      _url = cachedOriginalMxcUrl(ref, rawUrl) ?? source.previewUrl ?? url;
      _resolveFailed = _url == null;
      if (cachedOriginalMxcUrl(ref, rawUrl) != null) {
        _original = _OriginalState.loading;
      }
    });
  }

  Future<void> _loadOriginal() async {
    if (_original == _OriginalState.resolving ||
        _original == _OriginalState.loading ||
        _original == _OriginalState.loaded) {
      return;
    }
    setState(() => _original = _OriginalState.resolving);
    final url = await resolveMxcUrlFull(ref, widget.source.imageUrl);
    if (!mounted) return;
    setState(() {
      if (url == null || url.isEmpty) {
        _original = _OriginalState.failed;
      } else {
        _url = url;
        _original = _OriginalState.loading;
      }
    });
  }

  Future<void> _download() async {
    if (_downloading) return;
    setState(() => _downloading = true);
    final account = ref.read(activeUserIdProvider);
    try {
      final source = widget.source;
      final bytes =
          _bytes ??
          (source.mediaSourceJson != null
              ? await rust.downloadMediaSourceBytes(
                  mediaSourceJson: source.mediaSourceJson!,
                  maxSizeBytes: 128 * 1024 * 1024,
                )
              : source.imageUrl != null
              ? await rust.downloadMediaBytes(mxcUrl: source.imageUrl!)
              : null);
      if (!mounted || ref.read(activeUserIdProvider) != account) return;
      if (bytes == null || bytes.isEmpty) throw StateError('图片不可用');
      final filename = sanitizeAttachmentFilename(
        source.filename ?? 'image.png',
      );
      final saved = await saveDownloadedFile(filename: filename, bytes: bytes);
      if (mounted && saved) _notify('图片已保存');
    } catch (error) {
      if (mounted) _notify('下载失败: $error');
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _forward() async {
    if (_forwarding) return;
    setState(() => _forwarding = true);
    try {
      final room = await showForwardMessageSheet(
        context: context,
        sourceRoomId: widget.roomId!,
        message: widget.source.message!,
      );
      if (mounted && room != null) {
        _notify('已转发到 ${room.name}');
        widget.onMessageForwarded?.call(room);
      }
    } finally {
      if (mounted) setState(() => _forwarding = false);
    }
  }

  void _jump() {
    Navigator.of(context).pop();
    widget.onMessageJumpRequested?.call(widget.source.id);
  }

  void _notify(String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    final busy =
        _original == _OriginalState.resolving ||
        _original == _OriginalState.loading;
    final label = switch (_original) {
      _OriginalState.thumbnail => '原图',
      _OriginalState.resolving => '获取中',
      _OriginalState.loading => '加载中',
      _OriginalState.loaded => '已原图',
      _OriginalState.failed => '重试原图',
    };
    final displayedUrl = _url;
    return Stack(
      children: [
        Positioned.fill(
          child: ZoomableImageFrame(
            active: widget.active,
            onZoomChanged: widget.onZoomChanged,
            child: SizedBox.expand(
              child: Center(
                child: AspectRatio(
                  aspectRatio: widget.source.aspectRatio,
                  child: HeroMode(
                    enabled: widget.active,
                    child: Hero(
                      tag: widget.source.heroTag,
                      createRectTween: (begin, end) =>
                          RectTween(begin: begin, end: end),
                      flightShuttleBuilder: roundedImageFlightShuttle,
                      child: HeroImageClip(
                        borderRadius: BorderRadius.zero,
                        child: ChatMediaImage(
                          imageUrl: displayedUrl,
                          imageBytes: _bytes,
                          fit: BoxFit.contain,
                          onLoaded: () {
                            if (mounted &&
                                _url == displayedUrl &&
                                _original == _OriginalState.loading) {
                              setState(() => _original = _OriginalState.loaded);
                            }
                          },
                          onError: () {
                            if (mounted &&
                                _url == displayedUrl &&
                                _original == _OriginalState.loading) {
                              setState(() => _original = _OriginalState.failed);
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_url == null && _bytes == null)
          Positioned.fill(
            child: Center(
              child: _resolveFailed || _original == _OriginalState.failed
                  ? TextButton.icon(
                      onPressed: _resolveImage,
                      icon: const Icon(
                        Icons.refresh_rounded,
                        color: Colors.white,
                      ),
                      label: const Text(
                        '重新加载图片',
                        style: TextStyle(color: Colors.white),
                      ),
                    )
                  : const CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
            ),
          ),
        Positioned(
          top: MediaQuery.paddingOf(context).top,
          left: 0,
          right: 0,
          child: AppBar(
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            leading: IconButton(
              tooltip: '关闭',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close_rounded, color: Colors.white),
            ),
            actions: [
              if (widget.source.imageUrl?.startsWith('mxc://') == true)
                TextButton.icon(
                  onPressed: busy || _original == _OriginalState.loaded
                      ? null
                      : _loadOriginal,
                  icon: busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : Icon(
                          _original == _OriginalState.loaded
                              ? Icons.check_circle_rounded
                              : Icons.hd_rounded,
                          color: Colors.white,
                        ),
                  label: Text(
                    label,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              IconButton(
                tooltip: '下载',
                onPressed: _downloading ? null : _download,
                icon: Icon(
                  _downloading
                      ? Icons.downloading_rounded
                      : Icons.download_rounded,
                  color: Colors.white,
                ),
              ),
              if (widget.roomId != null &&
                  widget.source.message != null &&
                  !isLocalOutgoingMessage(widget.source.id))
                IconButton(
                  tooltip: '转发',
                  onPressed: _forwarding ? null : _forward,
                  icon: const Icon(Icons.forward_rounded, color: Colors.white),
                ),
              if (widget.onMessageJumpRequested != null &&
                  widget.source.message != null)
                IconButton(
                  tooltip: '转到该图片',
                  onPressed: _jump,
                  icon: const Icon(
                    Icons.chat_bubble_outline_rounded,
                    color: Colors.white,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
