import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/diagnostics/media_diagnostics.dart';
import '../providers/authenticated_media_cache.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/connection_provider.dart';
import '../theme/neu_colors.dart';

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
    this.radius = NeuRadius.content,
  });

  @override
  ConsumerState<AppAvatar> createState() => _AppAvatarState();
}

class _AppAvatarState extends ConsumerState<AppAvatar> {
  String? _resolvedUrl;
  int? _targetPixelSize;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextPixelSize = _avatarPixelSize(context, widget.size);
    if (_targetPixelSize != nextPixelSize || _resolvedUrl == null) {
      _targetPixelSize = nextPixelSize;
      _resolvedUrl = null;
      _maybeResolve();
    }
  }

  @override
  void didUpdateWidget(covariant AppAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Retry if URL changed, or if previous resolution failed (still null)
    if (widget.url != oldWidget.url ||
        widget.size != oldWidget.size ||
        _resolvedUrl == null) {
      _resolvedUrl = null;
      _maybeResolve();
    }
  }

  Future<void> _maybeResolve() async {
    final url = widget.url;
    if (url == null || url.isEmpty) return;
    if (url.startsWith('mxc://')) {
      final resolved = await resolveMxcUrlAvatar(ref, url);
      if (mounted && resolved != null) {
        setState(() => _resolvedUrl = resolved);
      }
      // If null, _resolvedUrl stays null → shows fallback; retried on next rebuild
    } else {
      if (mounted) {
        setState(() => _resolvedUrl = url);
      } else {
        _resolvedUrl = url;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = _resolvedUrl;
    final radius = context.isMaterial ? widget.size / 2 : widget.radius;

    if (url == null || url.isEmpty) {
      return _buildFallback(context);
    }

    // For HTTP URLs, use authenticated image loading
    final token = ref.watch(currentAccessTokenProvider);
    final currentUser = ref.watch(currentUserProvider);
    final activeUserId = ref.watch(activeUserIdProvider);
    final userId = currentUser?.id ?? activeUserId;
    final homeserver = currentUser?.homeserver;
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: context.neu.surfaceStrong,
        borderRadius: BorderRadius.circular(radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: _AuthenticatedImage(
        key: ValueKey('avatar-image:$url:${widget.size}'),
        url: url,
        token: token,
        userId: userId,
        homeserver: homeserver,
        fallback: _buildFallback(context),
        width: widget.size,
        height: widget.size,
        cacheWidth: _targetPixelSize,
        cacheHeight: _targetPixelSize,
      ),
    );
  }

  Widget _buildFallback(BuildContext context) {
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: context.isMaterial
            ? Theme.of(context).colorScheme.secondaryContainer
            : context.neu.surfaceStrong,
        borderRadius: BorderRadius.circular(
          context.isMaterial ? widget.size / 2 : widget.radius,
        ),
      ),
      child: Center(
        child: Text(
          _initials,
          style: TextStyle(
            color: context.isMaterial
                ? Theme.of(context).colorScheme.onSecondaryContainer
                : context.neu.accent,
            fontSize: widget.size * 0.38,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  String get _initials {
    final parts = widget.fallback
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return parts.isNotEmpty ? parts.first[0].toUpperCase() : '?';
  }
}

/// Cross-platform image widget using an Authorization header when required.
class _AuthenticatedImage extends ConsumerStatefulWidget {
  final String url;
  final String? token;
  final String? userId;
  final String? homeserver;
  final Widget fallback;
  final BoxFit? fit;
  final VoidCallback? onLoaded;
  final VoidCallback? onError;
  final double? width;
  final double? height;
  final int? cacheWidth;
  final int? cacheHeight;
  final bool useOldImageOnUrlChange;
  final Widget? loadingPlaceholder;

  const _AuthenticatedImage({
    super.key,
    required this.url,
    required this.token,
    required this.userId,
    required this.homeserver,
    required this.fallback,
    this.fit,
    this.onLoaded,
    this.onError,
    this.width,
    this.height,
    this.cacheWidth,
    this.cacheHeight,
    this.useOldImageOnUrlChange = false,
    this.loadingPlaceholder,
  });

  @override
  ConsumerState<_AuthenticatedImage> createState() =>
      _AuthenticatedImageState();
}

class _AuthenticatedImageState extends ConsumerState<_AuthenticatedImage> {
  bool _failed = false;
  int _retry = 0;
  Stopwatch _loadWatch = Stopwatch()..start();
  bool _failureLogged = false;

  void _startLoad() {
    _loadWatch = Stopwatch()..start();
    _failureLogged = false;
  }

  @override
  void didUpdateWidget(covariant _AuthenticatedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.url != oldWidget.url ||
        widget.userId != oldWidget.userId ||
        widget.homeserver != oldWidget.homeserver ||
        widget.cacheWidth != oldWidget.cacheWidth ||
        widget.cacheHeight != oldWidget.cacheHeight ||
        (_failed && widget.token != oldWidget.token)) {
      _startLoad();
    }
    if (widget.userId != oldWidget.userId ||
        widget.homeserver != oldWidget.homeserver ||
        (_failed &&
            (widget.url != oldWidget.url || widget.token != oldWidget.token))) {
      _failed = false;
      _retry++;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(connectionProvider, (previous, next) {
      if (_failed &&
          previous != AppConnectionState.connected &&
          next == AppConnectionState.connected) {
        // Rebuilding an equal image provider retains its failed stream.
        // Remount it to request the same URL again after sync recovers.
        setState(() {
          _startLoad();
          _failed = false;
          _retry++;
        });
      }
    });
    final isMatrixMedia = isCurrentHomeserverMatrixMediaUrl(
      widget.url,
      widget.homeserver,
    );
    final cacheKey = authenticatedMediaCacheKey(
      url: widget.url,
      userId: widget.userId,
      homeserver: widget.homeserver,
    );
    final cacheManager = authenticatedMediaCacheManager(
      url: widget.url,
      userId: widget.userId,
      homeserver: widget.homeserver,
    );
    return CachedNetworkImage(
      key: ValueKey(_retry),
      imageUrl: widget.url,
      cacheKey: cacheKey,
      cacheManager: cacheManager,
      httpHeaders: widget.token == null || !isMatrixMedia
          ? null
          : {'Authorization': 'Bearer ${widget.token}'},
      fit: widget.fit ?? BoxFit.cover,
      width: widget.width,
      height: widget.height,
      memCacheWidth: widget.cacheWidth,
      memCacheHeight: widget.cacheHeight,
      maxWidthDiskCache: widget.cacheWidth,
      maxHeightDiskCache: widget.cacheHeight,
      useOldImageOnUrlChange: widget.useOldImageOnUrlChange,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      imageBuilder: (context, imageProvider) {
        _loadWatch.stop();
        _failed = false;
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => widget.onLoaded?.call(),
        );
        return Image(
          image: imageProvider,
          fit: widget.fit ?? BoxFit.cover,
          width: widget.width,
          height: widget.height,
        );
      },
      placeholder: (context, _) =>
          widget.loadingPlaceholder ??
          Center(
            child: CircularProgressIndicator(
              color: context.neu.accent,
              strokeWidth: 1.5,
            ),
          ),
      errorWidget: (context, url, error) {
        _failed = true;
        _loadWatch.stop();
        if (!_failureLogged) {
          _failureLogged = true;
          logMediaLoadFailure(
            url: url,
            error: error,
            elapsedMs: _loadWatch.elapsedMilliseconds,
            attempt: _retry + 1,
            connection: ref.read(connectionProvider).name,
            authenticated: isMatrixMedia && widget.token != null,
          );
        }
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => widget.onError?.call(),
        );
        return widget.fallback;
      },
    );
  }
}

/// Authenticated image widget for message bubbles (larger images).
class AuthenticatedImageMessage extends ConsumerWidget {
  final String imageUrl;
  final Widget? loadingPlaceholder;
  final VoidCallback? onTap;
  final BoxFit? fit;
  final VoidCallback? onLoaded;
  final VoidCallback? onError;
  final int? cacheWidth;
  final int? cacheHeight;

  const AuthenticatedImageMessage({
    super.key,
    required this.imageUrl,
    this.loadingPlaceholder,
    this.onTap,
    this.fit,
    this.onLoaded,
    this.onError,
    this.cacheWidth,
    this.cacheHeight,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // mxc:// URLs can't be shown directly
    if (imageUrl.startsWith('mxc://')) {
      WidgetsBinding.instance.addPostFrameCallback((_) => onError?.call());
      return Center(
        child: Icon(
          Icons.broken_image_rounded,
          color: context.neu.textTertiary,
          size: 40,
        ),
      );
    }

    final token = ref.watch(currentAccessTokenProvider);
    final currentUser = ref.watch(currentUserProvider);
    final activeUserId = ref.watch(activeUserIdProvider);
    final userId = currentUser?.id ?? activeUserId;
    final homeserver = currentUser?.homeserver;
    final brokenIcon = Center(
      child: Icon(
        Icons.broken_image_rounded,
        color: context.neu.textTertiary,
        size: 40,
      ),
    );

    final imageWidget = _AuthenticatedImage(
      url: imageUrl,
      token: token,
      userId: userId,
      homeserver: homeserver,
      fallback: brokenIcon,
      fit: fit ?? BoxFit.cover,
      onLoaded: onLoaded,
      onError: onError,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
      useOldImageOnUrlChange: true,
      loadingPlaceholder: loadingPlaceholder,
    );

    if (onTap != null) {
      return GestureDetector(onTap: onTap, child: imageWidget);
    }
    return imageWidget;
  }
}

int _avatarPixelSize(BuildContext context, double logicalSize) {
  final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
  return math.max(48, (logicalSize * devicePixelRatio).round());
}
