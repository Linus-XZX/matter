import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import 'image_loading_policy.dart';

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

enum OriginalImageState { thumbnail, resolving, loading, loaded, failed }

/// Media state shared by an image page and the gallery's fixed toolbar.
class ImageViewerMedia extends ChangeNotifier {
  final ImageViewerSource source;
  final WidgetRef _ref;
  String? _url;
  Uint8List? _bytes;
  OriginalImageState _original = OriginalImageState.thumbnail;
  bool _resolveFailed = false;
  bool _disposed = false;

  ImageViewerMedia(this.source, this._ref) {
    _url = source.previewUrl;
    _bytes = source.imageBytes;
    unawaited(resolveImage());
  }

  String? get url => _url;
  Uint8List? get bytes => _bytes;
  OriginalImageState get original => _original;
  bool get resolveFailed => _resolveFailed;

  void _update(VoidCallback update) {
    if (_disposed) return;
    update();
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }

  Future<void> resolveImage() async {
    _resolveFailed = false;
    if (_bytes != null) {
      _original = OriginalImageState.loaded;
      return;
    }
    if (source.imageUrl == null && source.mediaSourceJson != null) {
      _update(() => _original = OriginalImageState.resolving);
      try {
        final bytes = await rust.downloadMediaSourceBytes(
          mediaSourceJson: source.mediaSourceJson!,
          maxSizeBytes: 64 * 1024 * 1024,
        );
        _update(() {
          _bytes = bytes;
          _original = OriginalImageState.loading;
        });
      } catch (_) {
        _update(() => _original = OriginalImageState.failed);
      }
      return;
    }
    final rawUrl = source.imageUrl;
    if (rawUrl == null) return;
    if (!rawUrl.startsWith('mxc://')) {
      _update(() {
        _url = rawUrl;
        _original = OriginalImageState.loading;
      });
      return;
    }
    if (cachedOriginalMxcUrl(_ref, rawUrl) != null ||
        shouldAutoLoadOriginal(
          fileSize: source.fileSize,
          mimeType: source.mimeType,
          filename: source.filename,
        )) {
      await loadOriginal();
      return;
    }
    if (source.previewUrl != null) return;
    final url = await resolveMxcUrl(
      _ref,
      rawUrl,
      width: 1600,
      height: 1200,
      useOriginalIfCached: true,
    );
    if (_disposed) return;
    _update(() {
      _url = cachedOriginalMxcUrl(_ref, rawUrl) ?? source.previewUrl ?? url;
      _resolveFailed = _url == null;
      if (cachedOriginalMxcUrl(_ref, rawUrl) != null) {
        _original = OriginalImageState.loading;
      }
    });
  }

  Future<void> loadOriginal() async {
    if (_original == OriginalImageState.resolving ||
        _original == OriginalImageState.loading ||
        _original == OriginalImageState.loaded) {
      return;
    }
    _update(() => _original = OriginalImageState.resolving);
    final url = await resolveMxcUrlFull(_ref, source.imageUrl);
    _update(() {
      if (url == null || url.isEmpty) {
        _original = OriginalImageState.failed;
      } else {
        _url = url;
        _original = OriginalImageState.loading;
      }
    });
  }

  void markLoaded(String? displayedUrl) {
    if (_url == displayedUrl && _original == OriginalImageState.loading) {
      _update(() => _original = OriginalImageState.loaded);
    }
  }

  void markFailed(String? displayedUrl) {
    if (_url == displayedUrl && _original == OriginalImageState.loading) {
      _update(() => _original = OriginalImageState.failed);
    }
  }
}
