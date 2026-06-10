import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/chat_provider.dart';
import '../src/rust/api/matrix.dart' as rust;
import '../theme/app_theme.dart';

/// Cached access token for authenticated image loading.
final _accessTokenProvider = FutureProvider<String?>((ref) async {
  return rust.getAccessToken();
});

class AppAvatar extends ConsumerStatefulWidget {
  final double size;
  final String? url;
  final String fallback;
  final double radius;

  const AppAvatar({
    super.key,
    this.size = 52,
    this.url,
    required this.fallback,
    this.radius = AppRadii.content,
  });

  @override
  ConsumerState<AppAvatar> createState() => _AppAvatarState();
}

class _AppAvatarState extends ConsumerState<AppAvatar> {
  String? _resolvedUrl;

  @override
  void initState() {
    super.initState();
    _maybeResolve();
  }

  @override
  void didUpdateWidget(covariant AppAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Retry if URL changed, or if previous resolution failed (still null)
    if (widget.url != oldWidget.url || _resolvedUrl == null) {
      _resolvedUrl = null;
      _maybeResolve();
    }
  }

  Future<void> _maybeResolve() async {
    final url = widget.url;
    if (url == null || url.isEmpty) return;
    if (url.startsWith('mxc://')) {
      final resolved = await resolveMxcUrl(ref, url);
      if (mounted && resolved != null) {
        setState(() => _resolvedUrl = resolved);
      }
      // If null, _resolvedUrl stays null → shows fallback; retried on next rebuild
    } else {
      _resolvedUrl = url;
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = _resolvedUrl;

    if (url == null || url.isEmpty) {
      return _buildFallback();
    }

    // For HTTP URLs, use authenticated image loading
    final tokenAsync = ref.watch(_accessTokenProvider);
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(widget.radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: tokenAsync.when(
        data: (token) => _AuthenticatedImage(
          url: url,
          token: token,
          fallback: _buildFallback(),
        ),
        loading: () => _buildFallback(),
        error: (_, _) => _buildFallback(),
      ),
    );
  }

  Widget _buildFallback() {
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(widget.radius),
      ),
      child: Center(
        child: Text(
          _initials,
          style: TextStyle(
            color: AppColors.primary,
            fontSize: widget.size * 0.38,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  String get _initials {
    final parts = widget.fallback.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return widget.fallback.isNotEmpty ? widget.fallback[0].toUpperCase() : '?';
  }
}

/// Image widget that downloads via dart:io HttpClient with Authorization header.
class _AuthenticatedImage extends StatefulWidget {
  final String url;
  final String? token;
  final Widget fallback;
  final BoxFit? fit;

  const _AuthenticatedImage({
    required this.url,
    required this.token,
    required this.fallback,
    this.fit,
  });

  @override
  State<_AuthenticatedImage> createState() => _AuthenticatedImageState();
}

/// Simple in-memory image cache to avoid re-downloading.
class _ImageCache {
  static final Map<String, Uint8List> _cache = {};
  static const int _maxSize = 80;

  static Uint8List? get(String url) => _cache[url];

  static void put(String url, Uint8List bytes) {
    if (_cache.length >= _maxSize) {
      // Evict oldest entry
      _cache.remove(_cache.keys.first);
    }
    _cache[url] = bytes;
  }
}

class _AuthenticatedImageState extends State<_AuthenticatedImage> {
  Uint8List? _imageBytes;
  bool _loading = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  @override
  void didUpdateWidget(covariant _AuthenticatedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.url != oldWidget.url) {
      _imageBytes = null;
      _loading = true;
      _error = false;
      _loadImage();
    }
  }

  Future<void> _loadImage() async {
    // Check cache first
    final cached = _ImageCache.get(widget.url);
    if (cached != null) {
      if (mounted) {
        setState(() {
          _imageBytes = cached;
          _loading = false;
        });
      }
      return;
    }

    try {
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(widget.url));
      if (widget.token != null) {
        request.headers.set('Authorization', 'Bearer ${widget.token}');
      }
      final response = await request.close();
      if (response.statusCode == 200) {
        final bytesBuilder = BytesBuilder();
        await for (final chunk in response) {
          bytesBuilder.add(chunk);
        }
        final bytes = bytesBuilder.toBytes();
        _ImageCache.put(widget.url, bytes);
        if (mounted) {
          setState(() {
            _imageBytes = bytes;
            _loading = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = true;
          });
        }
      }
      client.close();
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(
          color: AppColors.primary,
          strokeWidth: 1.5,
        ),
      );
    }
    if (_error || _imageBytes == null) {
      return widget.fallback;
    }
    return Image.memory(
      _imageBytes!,
      fit: widget.fit ?? BoxFit.cover,
      errorBuilder: (context, error, stackTrace) => widget.fallback,
    );
  }
}

/// Authenticated image widget for message bubbles (larger images).
class AuthenticatedImageMessage extends ConsumerWidget {
  final String imageUrl;
  final VoidCallback? onTap;
  final BoxFit? fit;

  const AuthenticatedImageMessage({
    super.key,
    required this.imageUrl,
    this.onTap,
    this.fit,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // mxc:// URLs can't be shown directly
    if (imageUrl.startsWith('mxc://')) {
      return const Center(
        child: Icon(
          Icons.broken_image_rounded,
          color: AppColors.onSurfaceVariant,
          size: 40,
        ),
      );
    }

    final tokenAsync = ref.watch(_accessTokenProvider);
    final brokenIcon = const Center(
      child: Icon(
        Icons.broken_image_rounded,
        color: AppColors.onSurfaceVariant,
        size: 40,
      ),
    );

    final imageWidget = tokenAsync.when(
      data: (token) => _AuthenticatedImage(
        url: imageUrl,
        token: token,
        fallback: brokenIcon,
        fit: fit ?? BoxFit.cover,
      ),
      loading: () => const Center(
        child: CircularProgressIndicator(
          color: AppColors.primary,
          strokeWidth: 2,
        ),
      ),
      error: (_, _) => brokenIcon,
    );

    if (onTap != null) {
      return GestureDetector(onTap: onTap, child: imageWidget);
    }
    return imageWidget;
  }
}
