import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/app_theme.dart';
import '../chat/chat_image_editor_page.dart';
import '../chat/latest_message_control.dart';

/// The four attachment modes offered by the floating frosted-glass bar.
enum AttachmentTab { media, file, poll, location }

/// Whether [photo_manager]'s native gallery grid works on this platform.
/// On Web/Linux/Windows it has no implementation and must be replaced with a
/// [file_selector] fallback to avoid MissingPluginException.
bool get photoManagerSupported =>
    !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

/// A full-screen attachment picker with a floating frosted-glass mode bar at
/// the bottom, mirroring the Telegram/Discord "plus" composer flow.
///
/// Replaces the old mandatory image-editor step: images are *confirmed* in a
/// multi-select grid and editing is an opt-in action (tap a thumbnail to open
/// the editor for a single image).
class AttachmentPicker extends StatefulWidget {
  final String roomId;
  final Future<void> Function(String roomId) onRefresh;
  final MessageSendPresentation Function() resolveSendPresentation;
  final void Function(
    MessageSendPresentation presentation,
    bool insertedOptimistically,
  )
  onMessageSent;

  const AttachmentPicker({
    super.key,
    required this.roomId,
    required this.onRefresh,
    required this.resolveSendPresentation,
    required this.onMessageSent,
  });

  @override
  State<AttachmentPicker> createState() => _AttachmentPickerState();
}

class _AttachmentPickerState extends State<AttachmentPicker> {
  AttachmentTab _tab = AttachmentTab.media;
  bool _isSending = false;

  /// Every Dart/FRB upload buffer is capped to avoid multiplying a very large
  /// allocation while it crosses the bridge into Rust.
  static const int _maxBufferedBytes = 64 * 1024 * 1024;
  static const int _maxImageEdge = 4096;
  static const int _maxImageQuality = 92;

  Future<void> _sendMediaAssets(List<AssetEntity> assets) => _runBatch(
    assets
        .map(
          (a) =>
              () => _sendSingleAsset(a),
        )
        .toList(),
    assets,
  );

  Future<void> _sendSingleAsset(AssetEntity asset) async {
    final file = await asset.originFile;
    if (file == null) throw '无法读取文件';
    final title = (await asset.titleAsync).trim();
    final filename = title.isEmpty ? 'asset_${asset.id}' : title;
    String? declaredMime;
    try {
      declaredMime = await asset.mimeTypeAsync;
    } catch (_) {
      // The filename fallback below is enough when a platform has no MIME API.
    }
    final mime = resolveAttachmentMime(filename, declaredMime);

    if (asset.type == AssetType.video) {
      final bytes = await _readFileBytes(file, '视频');
      final size = asset.size;
      await rust.sendVideoMessage(
        roomId: widget.roomId,
        videoData: bytes,
        filename: filename,
        width: size.width.round(),
        height: size.height.round(),
        durationMs: asset.videoDuration.inMilliseconds,
        size: bytes.length,
        mimeType: mime?.startsWith('video/') == true ? mime : null,
      );
      return;
    }

    if (asset.type == AssetType.image) {
      final prepared = await _prepareAssetImage(
        asset: asset,
        file: file,
        filename: filename,
        mimeType: mime,
      );
      await rust.sendImageMessage(
        roomId: widget.roomId,
        imageData: prepared.bytes,
        filename: prepared.filename,
        mimeType: prepared.mimeType,
        width: prepared.width,
        height: prepared.height,
      );
    } else {
      final bytes = await _readFileBytes(file, '文件');
      await rust.sendFileMessage(
        roomId: widget.roomId,
        fileData: bytes,
        filename: filename,
        mimeType: mime,
        size: bytes.length,
      );
    }
  }

  Future<void> _sendMediaXFiles(List<XFile> files) => _runBatch(
    files
        .map(
          (file) =>
              () => _sendSingleMediaXFile(file),
        )
        .toList(),
    files,
  );

  Future<void> _sendFiles(List<XFile> files) => _runBatch(
    files
        .map(
          (file) =>
              () => _sendSingleFile(file),
        )
        .toList(),
    files,
  );

  Future<void> _sendSingleMediaXFile(XFile file) async {
    final mime = resolveAttachmentMime(file.name, file.mimeType);
    final kind = classifyAttachmentMime(mime);
    final original = await _readXFileBytes(file);

    if (kind == AttachmentMediaKind.image) {
      final prepared = await _prepareBufferedImage(
        original,
        filename: file.name,
        mimeType: mime!,
      );
      await rust.sendImageMessage(
        roomId: widget.roomId,
        imageData: prepared.bytes,
        filename: prepared.filename,
        mimeType: prepared.mimeType,
        width: prepared.width,
        height: prepared.height,
      );
    } else if (kind == AttachmentMediaKind.video) {
      await rust.sendVideoMessage(
        roomId: widget.roomId,
        videoData: original,
        filename: file.name,
        mimeType: mime,
        size: original.length,
      );
    } else {
      await rust.sendFileMessage(
        roomId: widget.roomId,
        fileData: original,
        filename: file.name,
        mimeType: mime,
        size: original.length,
      );
    }
  }

  Future<void> _sendSingleFile(XFile file) async {
    final bytes = await _readXFileBytes(file);
    await rust.sendFileMessage(
      roomId: widget.roomId,
      fileData: bytes,
      filename: file.name,
      mimeType: resolveAttachmentMime(file.name, file.mimeType),
      size: bytes.length,
    );
  }

  Future<Uint8List> _readXFileBytes(XFile file) async {
    _ensureBufferedSize(await file.length(), '文件');
    final bytes = await file.readAsBytes();
    _ensureBufferedSize(bytes.length, '文件');
    return bytes;
  }

  Future<_PreparedImage> _prepareAssetImage({
    required AssetEntity asset,
    required File file,
    required String filename,
    required String? mimeType,
  }) async {
    final sourceSize = asset.size;
    if (sourceSize.width <= 0 || sourceSize.height <= 0) {
      final original = await _readFileBytes(file, '图片');
      final detectedMime = mimeType ?? _guessMime(filename);
      if (detectedMime?.startsWith('image/') != true) {
        throw '无法识别图片格式';
      }
      return _prepareBufferedImage(
        original,
        filename: filename,
        mimeType: detectedMime!,
      );
    }

    final target = _boundedImageSize(sourceSize);
    final shouldConvert =
        !_canSendOriginalImageMime(mimeType) ||
        sourceSize.width > _maxImageEdge ||
        sourceSize.height > _maxImageEdge;
    if (shouldConvert) {
      try {
        final compressed = await FlutterImageCompress.compressWithFile(
          file.path,
          minWidth: target.width,
          minHeight: target.height,
          quality: _maxImageQuality,
          format: CompressFormat.jpeg,
        );
        if (compressed != null && compressed.isNotEmpty) {
          return _jpegImage(
            compressed,
            filename: filename,
            expectedSize: target,
          );
        }
      } catch (_) {
        // A correctly typed original is still safe when it is already bounded.
      }
    }

    if (sourceSize.width > _maxImageEdge || sourceSize.height > _maxImageEdge) {
      throw '图片缩放失败';
    }
    if (mimeType?.startsWith('image/') != true) {
      throw '无法识别图片格式';
    }
    final original = await _readFileBytes(file, '图片');
    return _PreparedImage(
      bytes: original,
      filename: filename,
      mimeType: mimeType!,
      width: sourceSize.width.round(),
      height: sourceSize.height.round(),
    );
  }

  Future<_PreparedImage> _prepareBufferedImage(
    Uint8List original, {
    required String filename,
    required String mimeType,
  }) async {
    final sourceSize = await _decodeImageSize(original);
    if (sourceSize == null) throw '无法读取图片尺寸';
    final target = _boundedImageSize(sourceSize);
    final shouldConvert =
        !_canSendOriginalImageMime(mimeType) ||
        sourceSize.width > _maxImageEdge ||
        sourceSize.height > _maxImageEdge;
    if (!shouldConvert) {
      return _PreparedImage(
        bytes: original,
        filename: filename,
        mimeType: mimeType,
        width: sourceSize.width.round(),
        height: sourceSize.height.round(),
      );
    }

    try {
      final compressed = await FlutterImageCompress.compressWithList(
        original,
        minWidth: target.width,
        minHeight: target.height,
        quality: _maxImageQuality,
        format: CompressFormat.jpeg,
      );
      if (compressed.isNotEmpty) {
        return _jpegImage(compressed, filename: filename, expectedSize: target);
      }
    } catch (_) {
      // Preserve a correctly typed original only when it is already bounded.
    }

    if (sourceSize.width > _maxImageEdge || sourceSize.height > _maxImageEdge) {
      throw '图片缩放失败';
    }
    return _PreparedImage(
      bytes: original,
      filename: filename,
      mimeType: mimeType,
      width: sourceSize.width.round(),
      height: sourceSize.height.round(),
    );
  }

  Future<_PreparedImage> _jpegImage(
    Uint8List bytes, {
    required String filename,
    required ({int width, int height}) expectedSize,
  }) async {
    _ensureBufferedSize(bytes.length, '图片');
    final actual = await _decodeImageSize(bytes);
    final width = actual?.width.round() ?? expectedSize.width;
    final height = actual?.height.round() ?? expectedSize.height;
    if (width > _maxImageEdge || height > _maxImageEdge) {
      throw '图片缩放后仍超过 ${_maxImageEdge}px';
    }
    return _PreparedImage(
      bytes: bytes,
      filename: _withExtension(filename, 'jpg'),
      mimeType: 'image/jpeg',
      width: width,
      height: height,
    );
  }

  Future<Uint8List> _readFileBytes(File file, String label) async {
    _ensureBufferedSize(await file.length(), label);
    final bytes = await file.readAsBytes();
    _ensureBufferedSize(bytes.length, label);
    return bytes;
  }

  void _ensureBufferedSize(int length, String label) {
    if (length > _maxBufferedBytes) {
      throw '$label超过 ${_maxBufferedBytes ~/ 1024 ~/ 1024}MB 限制';
    }
  }

  Future<void> _sendEditedImage(
    Uint8List bytes, {
    required String originalFilename,
    required String? originalMimeType,
  }) => _runBatch([
    () async {
      _ensureBufferedSize(bytes.length, '图片');
      final mimeType =
          detectImageMime(bytes) ??
          resolveAttachmentMime(originalFilename, originalMimeType);
      if (mimeType?.startsWith('image/') != true) {
        throw '无法识别编辑后的图片格式';
      }
      final filename = _withExtension(
        originalFilename,
        _imageExtensionForMime(mimeType!),
      );
      final imageSize = await _decodeImageSize(bytes);
      await rust.sendImageMessage(
        roomId: widget.roomId,
        imageData: bytes,
        filename: filename,
        mimeType: mimeType,
        width: imageSize?.width.round(),
        height: imageSize?.height.round(),
      );
    },
  ], null);

  Future<void> _sendPoll(
    String question,
    List<String> answers,
    bool disclosed,
  ) => _runBatch([
    () => rust.sendPoll(
      roomId: widget.roomId,
      question: question,
      answers: answers,
      disclosed: disclosed,
    ),
  ], null);

  Future<void> _sendLocation(String body, String geoUri) => _runBatch([
    () => rust.sendLocation(roomId: widget.roomId, body: body, geoUri: geoUri),
  ], null);

  /// Sends a batch of individual send operations, tracking per-item success so
  /// a partial failure does not re-send already-delivered items on retry, and
  /// so a refresh failure is never misreported as a send failure.
  ///
  /// [items] carries the source selection so successfully-sent entries can be
  /// pruned from the UI; pass `null` for non-batch sends (poll/location/edit).
  Future<void> _runBatch(
    List<Future<void> Function()> ops,
    List<dynamic>? items,
  ) async {
    if (_isSending || ops.isEmpty) return;
    setState(() => _isSending = true);
    final presentation = widget.resolveSendPresentation();
    var sent = 0;
    try {
      for (var i = 0; i < ops.length; i++) {
        try {
          await ops[i]();
          sent++;
          // Prune the head: ops and items advance in lockstep, so after a
          // success the list tail == remaining unsent items. On full success
          // the list is empty; on partial failure the user keeps the unsent
          // remainder, so a retry never re-sends delivered items.
          if (items != null && items.isNotEmpty) {
            items.removeAt(0);
          }
          if (mounted) setState(() {});
        } catch (e) {
          if (sent > 0) {
            await _finishBatch(presentation, closePicker: false);
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(sent > 0 ? '已发送 $sent 项; 随后失败: $e' : '发送失败: $e'),
                duration: const Duration(seconds: 2),
              ),
            );
          }
          return;
        }
      }
      await _finishBatch(presentation, closePicker: true);
    } finally {
      if (mounted && _isSending) setState(() => _isSending = false);
    }
  }

  /// Best-effort refresh + completion callback. A refresh error is swallowed
  /// (it does not invalidate already-sent messages).
  Future<void> _finishBatch(
    MessageSendPresentation presentation, {
    required bool closePicker,
  }) async {
    try {
      await widget.onRefresh(widget.roomId);
    } catch (_) {
      // Refresh is best-effort; never surface as a send failure.
    }
    if (!mounted) return;
    widget.onMessageSent(presentation, false);
    if (closePicker) {
      setState(() => _isSending = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final titles = const {
      AttachmentTab.media: '图片 / 视频',
      AttachmentTab.file: '文件',
      AttachmentTab.poll: '投票',
      AttachmentTab.location: '位置',
    };
    final tabs = <Widget>[
      photoManagerSupported
          ? _MediaTabBody(
              isSending: _isSending,
              onSendAssets: _sendMediaAssets,
              onOpenEditor: (source) async {
                final edited = await Navigator.of(context).push<Uint8List>(
                  MaterialPageRoute(
                    fullscreenDialog: true,
                    builder: (_) => ChatImageEditorPage(
                      imagePath: source.path,
                      mimeType: source.mimeType,
                    ),
                  ),
                );
                if (edited != null && mounted) {
                  await _sendEditedImage(
                    edited,
                    originalFilename: source.filename,
                    originalMimeType: source.mimeType,
                  );
                }
              },
            )
          : _MediaFallback(
              isSending: _isSending,
              onSendFiles: _sendMediaXFiles,
            ),
      _FileTabBody(isSending: _isSending, onSendFiles: _sendFiles),
      _PollTabBody(isSending: _isSending, onSendPoll: _sendPoll),
      _LocationTabBody(isSending: _isSending, onSendLocation: _sendLocation),
    ];
    return PopScope(
      canPop: !_isSending,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.background,
          foregroundColor: AppColors.onBackground,
          elevation: 0,
          title: Text(titles[_tab]!),
          leading: IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: _isSending
                ? null
                : () => Navigator.of(context).maybePop(),
          ),
        ),
        body: Stack(
          children: [
            IndexedStack(index: _tab.index, children: tabs),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: _FrostedTabBar(
                  tab: _tab,
                  onTabChanged: _isSending
                      ? null
                      : (tab) => setState(() => _tab = tab),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Frosted-glass mode bar ────────────────────────────────────────────

class _FrostedTabBar extends StatelessWidget {
  final AttachmentTab tab;
  final ValueChanged<AttachmentTab>? onTabChanged;

  const _FrostedTabBar({required this.tab, required this.onTabChanged});

  @override
  Widget build(BuildContext context) {
    final items = const [
      _TabItem(AttachmentTab.media, Icons.photo_library_rounded, '图片'),
      _TabItem(AttachmentTab.file, Icons.folder_rounded, '文件'),
      _TabItem(AttachmentTab.poll, Icons.poll_rounded, '投票'),
      _TabItem(AttachmentTab.location, Icons.location_on_rounded, '地址'),
    ];
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.glassBackground,
            borderRadius: BorderRadius.circular(AppRadii.nav),
            border: Border.all(color: AppColors.glassBorder, width: 0.8),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              for (final item in items)
                _TabButton(
                  item: item,
                  selected: tab == item.tab,
                  onTap: onTabChanged == null
                      ? null
                      : () => onTabChanged!(item.tab),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabItem {
  final AttachmentTab tab;
  final IconData icon;
  final String label;
  const _TabItem(this.tab, this.icon, this.label);
}

class _TabButton extends StatelessWidget {
  final _TabItem item;
  final bool selected;
  final VoidCallback? onTap;

  const _TabButton({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.primary : AppColors.onSurfaceVariant;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(item.icon, color: color, size: 24),
            const SizedBox(height: 2),
            Text(item.label, style: TextStyle(color: color, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

// ── Media tab: gallery grid + multi-select ───────────────────────────

typedef _ImageEditorSource = ({String path, String filename, String? mimeType});

class _MediaTabBody extends StatefulWidget {
  final bool isSending;
  final Future<void> Function(List<AssetEntity> assets) onSendAssets;
  final Future<void> Function(_ImageEditorSource source) onOpenEditor;

  const _MediaTabBody({
    required this.isSending,
    required this.onSendAssets,
    required this.onOpenEditor,
  });

  @override
  State<_MediaTabBody> createState() => _MediaTabBodyState();
}

class _MediaTabBodyState extends State<_MediaTabBody> {
  AssetPathEntity? _album;
  final List<AssetEntity> _assets = [];
  final List<AssetEntity> _selected = [];
  bool _loading = true;
  String? _error;
  bool _fetchingMore = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final perm = await PhotoManager.requestPermissionExtend();
      if (!mounted) return;
      if (!perm.hasAccess) {
        setState(() {
          _loading = false;
          _error = '没有相册访问权限';
        });
        return;
      }
      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.common,
        hasAll: true,
      );
      if (!mounted) return;
      if (albums.isEmpty) {
        setState(() => _loading = false);
        return;
      }
      final album = albums.firstWhere(
        (a) => a.isAll,
        orElse: () => albums.first,
      );
      final assets = await album.getAssetListPaged(page: 0, size: 100);
      if (!mounted) return;
      setState(() {
        _album = album;
        _assets.addAll(assets);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _fetchMore() async {
    final album = _album;
    if (_fetchingMore || album == null || !mounted) return;
    setState(() => _fetchingMore = true);
    try {
      final total = await album.assetCountAsync;
      if (!mounted || _assets.length >= total) return;
      final next = await album.getAssetListPaged(
        page: _assets.length ~/ 100,
        size: 100,
      );
      if (!mounted) return;
      setState(() => _assets.addAll(next));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('加载更多媒体失败: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _fetchingMore = false);
    }
  }

  bool _onScroll(ScrollNotification n) {
    if (n is ScrollEndNotification &&
        n.metrics.pixels >= n.metrics.maxScrollExtent - 240 &&
        _assets.isNotEmpty &&
        !_fetchingMore) {
      _fetchMore();
    }
    return false;
  }

  void _toggleSelect(AssetEntity asset) {
    if (widget.isSending) return;
    setState(() {
      if (_selected.contains(asset)) {
        _selected.remove(asset);
      } else {
        _selected.add(asset);
      }
    });
  }

  int _selectionIndex(AssetEntity asset) =>
      _selected.indexOf(asset) + 1; // 0 means not selected

  Future<void> _openEditor(AssetEntity asset) async {
    if (widget.isSending || asset.type != AssetType.image) return;
    try {
      final file = await asset.originFile;
      if (file == null) throw '无法读取原图';
      final title = (await asset.titleAsync).trim();
      final filename = title.isEmpty ? 'asset_${asset.id}' : title;
      String? declaredMime;
      try {
        declaredMime = await asset.mimeTypeAsync;
      } catch (_) {
        // The filename fallback is enough when MIME metadata is unavailable.
      }
      if (!mounted || widget.isSending) return;
      await widget.onOpenEditor((
        path: file.path,
        filename: filename,
        mimeType: resolveAttachmentMime(filename, declaredMime),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('打开图片失败: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            style: const TextStyle(color: AppColors.onSurfaceVariant),
          ),
        ),
      );
    }
    return Column(
      children: [
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: _assets.isEmpty
                ? const Center(
                    child: Text(
                      '没有可用的图片或视频',
                      style: TextStyle(color: AppColors.onSurfaceVariant),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(2, 2, 2, 96),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          mainAxisSpacing: 2,
                          crossAxisSpacing: 2,
                        ),
                    itemCount: _assets.length + (_fetchingMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index >= _assets.length) {
                        return const Center(
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.onSurfaceVariant,
                              ),
                            ),
                          ),
                        );
                      }
                      final asset = _assets[index];
                      final order = _selectionIndex(asset);
                      final selected = order > 0;
                      final isVideo = asset.type == AssetType.video;
                      return GestureDetector(
                        // Tapping a video must not open the image editor: it would
                        // feed video bytes to the image decoder. Videos toggle
                        // selection instead; only images open the editor.
                        onTap: widget.isSending
                            ? null
                            : isVideo
                            ? () => _toggleSelect(asset)
                            : () => _openEditor(asset),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              color: selected
                                  ? AppColors.background
                                  : Colors.transparent,
                              padding: selected
                                  ? const EdgeInsets.all(6)
                                  : EdgeInsets.zero,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(
                                  selected ? 8 : 0,
                                ),
                                child: _AssetThumbnail(asset: asset),
                              ),
                            ),
                            Positioned(
                              top: 4,
                              right: 4,
                              child: GestureDetector(
                                onTap: widget.isSending
                                    ? null
                                    : () => _toggleSelect(asset),
                                child: _SelectionBadge(
                                  selected: selected,
                                  order: order,
                                ),
                              ),
                            ),
                            if (isVideo)
                              const Positioned(
                                bottom: 4,
                                left: 4,
                                child: Icon(
                                  Icons.play_circle_fill,
                                  color: Colors.white70,
                                  size: 18,
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ),
        if (_selected.isNotEmpty)
          _SendBar(
            count: _selected.length,
            isSending: widget.isSending,
            // Pass by reference so partial-success items are pruned by the
            // send loop and a retry never re-sends delivered items.
            onSend: () => widget.onSendAssets(_selected),
          ),
      ],
    );
  }
}

class _AssetThumbnail extends StatelessWidget {
  final AssetEntity asset;
  const _AssetThumbnail({required this.asset});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: asset.thumbnailDataWithSize(const ThumbnailSize.square(256)),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Container(color: AppColors.surfaceVariant);
        }
        final bytes = snap.data;
        if (bytes == null) {
          return Container(
            color: AppColors.surfaceVariant,
            child: const Icon(
              Icons.broken_image,
              color: AppColors.onSurfaceVariant,
              size: 22,
            ),
          );
        }
        return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
      },
    );
  }
}

class _SelectionBadge extends StatelessWidget {
  final bool selected;
  final int order;
  const _SelectionBadge({required this.selected, required this.order});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected
            ? AppColors.primary
            : Colors.black.withValues(alpha: 0.35),
        border: Border.all(
          color: Colors.white.withValues(alpha: selected ? 0 : 0.7),
          width: 1.5,
        ),
      ),
      alignment: Alignment.center,
      child: selected
          ? Text(
              '$order',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}

class _SendBar extends StatelessWidget {
  final int count;
  final bool isSending;
  final bool enabled;
  final VoidCallback onSend;

  const _SendBar({
    required this.count,
    required this.isSending,
    required this.onSend,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final active = enabled && !isSending;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 96),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: active ? onSend : null,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              disabledBackgroundColor: AppColors.primary.withValues(
                alpha: 0.35,
              ),
              disabledForegroundColor: Colors.white.withValues(alpha: 0.7),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadii.button),
              ),
            ),
            icon: isSending
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.send_rounded),
            label: Text('发送 $count 项'),
          ),
        ),
      ),
    );
  }
}

// ── Media fallback (Web/Linux/Windows: no photo_manager) ─────────────

class _MediaFallback extends StatefulWidget {
  final bool isSending;
  final Future<void> Function(List<XFile> files) onSendFiles;

  const _MediaFallback({required this.isSending, required this.onSendFiles});

  @override
  State<_MediaFallback> createState() => _MediaFallbackState();
}

class _MediaFallbackState extends State<_MediaFallback> {
  final List<XFile> _picked = [];

  static const _groups = <XTypeGroup>[
    XTypeGroup(
      label: '图片 / 视频',
      extensions: [
        'jpg',
        'jpeg',
        'png',
        'gif',
        'webp',
        'heic',
        'heif',
        'avif',
        'tiff',
        'tif',
        'bmp',
        'mp4',
        'mov',
        'm4v',
        'webm',
        'mkv',
        '3gp',
      ],
    ),
  ];

  Future<void> _pick() async {
    if (widget.isSending) return;
    try {
      final files = await openFiles(acceptedTypeGroups: _groups);
      if (!mounted || widget.isSending || files.isEmpty) return;
      setState(() => _picked.addAll(files));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('选择媒体失败: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 120),
            children: [
              const Icon(
                Icons.photo_library_outlined,
                size: 48,
                color: AppColors.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              const Text(
                '此平台的相册网格不可用，请选择图片或视频',
                style: TextStyle(color: AppColors.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Center(
                child: OutlinedButton(
                  onPressed: widget.isSending ? null : _pick,
                  child: const Text('选择图片 / 视频'),
                ),
              ),
              const SizedBox(height: 12),
              for (var index = 0; index < _picked.length; index++)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.insert_drive_file_rounded,
                    color: AppColors.onSurfaceVariant,
                  ),
                  title: Text(
                    _picked[index].name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.onSurface,
                      fontSize: 13,
                    ),
                  ),
                  trailing: IconButton(
                    tooltip: '移除',
                    onPressed: widget.isSending
                        ? null
                        : () => setState(() => _picked.removeAt(index)),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ),
            ],
          ),
        ),
        if (_picked.isNotEmpty)
          _SendBar(
            count: _picked.length,
            isSending: widget.isSending,
            onSend: () => widget.onSendFiles(_picked),
          ),
      ],
    );
  }
}

// ── File tab ─────────────────────────────────────────────────────────

class _FileTabBody extends StatefulWidget {
  final bool isSending;
  final Future<void> Function(List<XFile> files) onSendFiles;

  const _FileTabBody({required this.isSending, required this.onSendFiles});

  @override
  State<_FileTabBody> createState() => _FileTabBodyState();
}

class _FileTabBodyState extends State<_FileTabBody> {
  List<XFile> _picked = const [];

  Future<void> _pick() async {
    if (widget.isSending) return;
    try {
      final files = await openFiles();
      if (!mounted || widget.isSending || files.isEmpty) return;
      setState(() => _picked = List.of(files));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('选择文件失败: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: _picked.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.folder_open_rounded,
                          size: 48,
                          color: AppColors.onSurfaceVariant,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          '选择要发送的文件',
                          style: TextStyle(color: AppColors.onSurfaceVariant),
                        ),
                        const SizedBox(height: 16),
                        OutlinedButton(
                          onPressed: widget.isSending ? null : _pick,
                          child: const Text('选择文件'),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 120),
                  itemCount: _picked.length,
                  itemBuilder: (context, index) {
                    final f = _picked[index];
                    return ListTile(
                      leading: const Icon(
                        Icons.insert_drive_file_rounded,
                        color: AppColors.onSurfaceVariant,
                      ),
                      title: Text(
                        f.name,
                        style: const TextStyle(color: AppColors.onBackground),
                      ),
                      trailing: IconButton(
                        icon: const Icon(
                          Icons.close_rounded,
                          color: AppColors.onSurfaceVariant,
                        ),
                        onPressed: widget.isSending
                            ? null
                            : () => setState(() => _picked.removeAt(index)),
                      ),
                    );
                  },
                ),
        ),
        if (_picked.isNotEmpty)
          _SendBar(
            count: _picked.length,
            isSending: widget.isSending,
            onSend: () => widget.onSendFiles(_picked),
          ),
      ],
    );
  }
}

// ── Poll tab ─────────────────────────────────────────────────────────

class _PollTabBody extends StatefulWidget {
  final bool isSending;
  final Future<void> Function(
    String question,
    List<String> answers,
    bool disclosed,
  )
  onSendPoll;

  const _PollTabBody({required this.isSending, required this.onSendPoll});

  @override
  State<_PollTabBody> createState() => _PollTabBodyState();
}

class _PollTabBodyState extends State<_PollTabBody> {
  final _question = TextEditingController();
  final List<TextEditingController> _answers = [
    TextEditingController(),
    TextEditingController(),
  ];
  bool _disclosed = false;

  @override
  void dispose() {
    _question.dispose();
    for (final c in _answers) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _canSend {
    if (_question.text.trim().isEmpty) return false;
    final valid = _answers.where((c) => c.text.trim().isNotEmpty).length;
    return valid >= 2;
  }

  List<String> get _validAnswers =>
      _answers.map((c) => c.text.trim()).where((s) => s.isNotEmpty).toList();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
            children: [
              TextField(
                controller: _question,
                enabled: !widget.isSending,
                style: const TextStyle(color: AppColors.onBackground),
                decoration: const InputDecoration(
                  labelText: '问题',
                  labelStyle: TextStyle(color: AppColors.onSurfaceVariant),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: AppColors.surfaceVariant),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: AppColors.primary),
                  ),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              for (var i = 0; i < _answers.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _answers[i],
                          enabled: !widget.isSending,
                          style: const TextStyle(color: AppColors.onBackground),
                          decoration: InputDecoration(
                            hintText: '选项 ${i + 1}',
                            hintStyle: const TextStyle(
                              color: AppColors.onSurfaceVariant,
                            ),
                            enabledBorder: const UnderlineInputBorder(
                              borderSide: BorderSide(
                                color: AppColors.surfaceVariant,
                              ),
                            ),
                            focusedBorder: const UnderlineInputBorder(
                              borderSide: BorderSide(color: AppColors.primary),
                            ),
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      if (_answers.length > 2)
                        IconButton(
                          icon: const Icon(
                            Icons.remove_circle_outline_rounded,
                            color: AppColors.onSurfaceVariant,
                          ),
                          onPressed: widget.isSending
                              ? null
                              : () {
                                  setState(() {
                                    _answers[i].dispose();
                                    _answers.removeAt(i);
                                  });
                                },
                        ),
                    ],
                  ),
                ),
              TextButton.icon(
                onPressed: widget.isSending || _answers.length >= 20
                    ? null
                    : () =>
                          setState(() => _answers.add(TextEditingController())),
                icon: const Icon(Icons.add_rounded),
                label: const Text(
                  '添加选项',
                  style: TextStyle(color: AppColors.primary),
                ),
              ),
              SwitchListTile(
                title: const Text(
                  '公开投票结果',
                  style: TextStyle(color: AppColors.onBackground),
                ),
                value: _disclosed,
                onChanged: widget.isSending
                    ? null
                    : (v) => setState(() => _disclosed = v),
                activeThumbColor: AppColors.primary,
              ),
            ],
          ),
        ),
        _SendBar(
          count: 1,
          isSending: widget.isSending,
          enabled: _canSend,
          onSend: () => widget.onSendPoll(
            _question.text.trim(),
            _validAnswers,
            _disclosed,
          ),
        ),
      ],
    );
  }
}

// ── Location tab ─────────────────────────────────────────────────────

class _LocationTabBody extends StatefulWidget {
  final bool isSending;
  final Future<void> Function(String body, String geoUri) onSendLocation;

  const _LocationTabBody({
    required this.isSending,
    required this.onSendLocation,
  });

  @override
  State<_LocationTabBody> createState() => _LocationTabBodyState();
}

class _LocationTabBodyState extends State<_LocationTabBody> {
  final _lat = TextEditingController();
  final _lng = TextEditingController();
  final _body = TextEditingController();

  String get _geoUri => canonicalGeoUri(_lat.text, _lng.text) ?? '';

  bool get _canSend => _geoUri.isNotEmpty;

  @override
  void dispose() {
    _lat.dispose();
    _lng.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _lat,
                      enabled: !widget.isSending,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                        signed: true,
                      ),
                      style: const TextStyle(color: AppColors.onBackground),
                      decoration: const InputDecoration(
                        labelText: '纬度',
                        labelStyle: TextStyle(
                          color: AppColors.onSurfaceVariant,
                        ),
                        enabledBorder: UnderlineInputBorder(
                          borderSide: BorderSide(
                            color: AppColors.surfaceVariant,
                          ),
                        ),
                        focusedBorder: UnderlineInputBorder(
                          borderSide: BorderSide(color: AppColors.primary),
                        ),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _lng,
                      enabled: !widget.isSending,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                        signed: true,
                      ),
                      style: const TextStyle(color: AppColors.onBackground),
                      decoration: const InputDecoration(
                        labelText: '经度',
                        labelStyle: TextStyle(
                          color: AppColors.onSurfaceVariant,
                        ),
                        enabledBorder: UnderlineInputBorder(
                          borderSide: BorderSide(
                            color: AppColors.surfaceVariant,
                          ),
                        ),
                        focusedBorder: UnderlineInputBorder(
                          borderSide: BorderSide(color: AppColors.primary),
                        ),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _body,
                enabled: !widget.isSending,
                style: const TextStyle(color: AppColors.onBackground),
                decoration: const InputDecoration(
                  labelText: '描述（可选）',
                  labelStyle: TextStyle(color: AppColors.onSurfaceVariant),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: AppColors.surfaceVariant),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: AppColors.primary),
                  ),
                ),
              ),
            ],
          ),
        ),
        _SendBar(
          count: 1,
          isSending: widget.isSending,
          enabled: _canSend,
          onSend: () => widget.onSendLocation(_body.text.trim(), _geoUri),
        ),
      ],
    );
  }
}

// ── Helpers ──────────────────────────────────────────────────────────

enum AttachmentMediaKind { image, video, file }

class _PreparedImage {
  final Uint8List bytes;
  final String filename;
  final String mimeType;
  final int width;
  final int height;

  const _PreparedImage({
    required this.bytes,
    required this.filename,
    required this.mimeType,
    required this.width,
    required this.height,
  });
}

@visibleForTesting
String? resolveAttachmentMime(String filename, String? declaredMime) {
  final declared = declaredMime?.split(';').first.trim().toLowerCase();
  if (declared != null &&
      declared.isNotEmpty &&
      declared != 'application/octet-stream') {
    return declared;
  }
  return _guessMime(filename) ?? (declared?.isEmpty == false ? declared : null);
}

@visibleForTesting
AttachmentMediaKind classifyAttachmentMime(String? mimeType) {
  if (mimeType?.startsWith('image/') == true) {
    return AttachmentMediaKind.image;
  }
  if (mimeType?.startsWith('video/') == true) {
    return AttachmentMediaKind.video;
  }
  return AttachmentMediaKind.file;
}

bool _canSendOriginalImageMime(String? mimeType) => const {
  'image/jpeg',
  'image/jpg',
  'image/png',
  'image/gif',
  'image/webp',
}.contains(mimeType);

({int width, int height}) _boundedImageSize(Size source) {
  if (source.width <= 0 || source.height <= 0) {
    return (
      width: _AttachmentPickerState._maxImageEdge,
      height: _AttachmentPickerState._maxImageEdge,
    );
  }
  final longest = source.width > source.height ? source.width : source.height;
  final scale = longest > _AttachmentPickerState._maxImageEdge
      ? _AttachmentPickerState._maxImageEdge / longest
      : 1.0;
  final width = (source.width * scale).floor();
  final height = (source.height * scale).floor();
  return (width: width > 0 ? width : 1, height: height > 0 ? height : 1);
}

final _decimalCoordinate = RegExp(r'^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$');

double? _parseCoordinate(String raw, {required double maxAbsolute}) {
  final valueText = raw.trim();
  if (!_decimalCoordinate.hasMatch(valueText)) return null;
  final value = double.tryParse(valueText);
  if (value == null || !value.isFinite || value.abs() > maxAbsolute) {
    return null;
  }
  return value;
}

String _formatCoordinate(double value) {
  if (value == 0) return '0';
  var result = value.toStringAsFixed(12);
  result = result.replaceFirst(RegExp(r'0+$'), '');
  return result.replaceFirst(RegExp(r'\.$'), '');
}

@visibleForTesting
String? canonicalGeoUri(String latitude, String longitude) {
  final lat = _parseCoordinate(latitude, maxAbsolute: 90);
  final lng = _parseCoordinate(longitude, maxAbsolute: 180);
  if (lat == null || lng == null) return null;
  return 'geo:${_formatCoordinate(lat)},${_formatCoordinate(lng)}';
}

String? _guessMime(String filename) {
  final lower = filename.toLowerCase();
  final dot = lower.lastIndexOf('.');
  if (dot < 0) return null;
  final ext = lower.substring(dot + 1);
  return const {
    // Images
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'heic': 'image/heic',
    'heif': 'image/heif',
    'avif': 'image/avif',
    'tiff': 'image/tiff',
    'tif': 'image/tiff',
    'bmp': 'image/bmp',
    // Video (case-insensitive: .MOV is common on iOS)
    'mp4': 'video/mp4',
    'm4v': 'video/mp4',
    'mov': 'video/quicktime',
    'webm': 'video/webm',
    'mkv': 'video/x-matroska',
    '3gp': 'video/3gpp',
    // Audio
    'mp3': 'audio/mpeg',
    'm4a': 'audio/mp4',
    'aac': 'audio/aac',
    'ogg': 'audio/ogg',
    'opus': 'audio/ogg',
    'wav': 'audio/wav',
    'flac': 'audio/flac',
    // Common documents
    'pdf': 'application/pdf',
    'txt': 'text/plain',
    'zip': 'application/zip',
  }[ext];
}

@visibleForTesting
String? detectImageMime(Uint8List bytes) {
  bool matches(int offset, List<int> signature) {
    if (bytes.length < offset + signature.length) return false;
    for (var index = 0; index < signature.length; index++) {
      if (bytes[offset + index] != signature[index]) return false;
    }
    return true;
  }

  if (matches(0, const [0xff, 0xd8, 0xff])) return 'image/jpeg';
  if (matches(0, const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
    return 'image/png';
  }
  if (matches(0, 'GIF87a'.codeUnits) || matches(0, 'GIF89a'.codeUnits)) {
    return 'image/gif';
  }
  if (matches(0, 'RIFF'.codeUnits) && matches(8, 'WEBP'.codeUnits)) {
    return 'image/webp';
  }
  if (matches(0, 'BM'.codeUnits)) return 'image/bmp';
  if (matches(0, const [0x49, 0x49, 0x2a, 0x00]) ||
      matches(0, const [0x4d, 0x4d, 0x00, 0x2a])) {
    return 'image/tiff';
  }
  if (matches(4, 'ftyp'.codeUnits) && bytes.length >= 12) {
    final brand = String.fromCharCodes(bytes.sublist(8, 12)).toLowerCase();
    if (brand == 'avif' || brand == 'avis') return 'image/avif';
    if ({'heic', 'heix', 'hevc', 'hevx'}.contains(brand)) {
      return 'image/heic';
    }
    if (brand == 'heif' || brand == 'mif1' || brand == 'msf1') {
      return 'image/heif';
    }
  }
  return null;
}

String _imageExtensionForMime(String mimeType) {
  return const {
        'image/jpeg': 'jpg',
        'image/jpg': 'jpg',
        'image/png': 'png',
        'image/gif': 'gif',
        'image/webp': 'webp',
        'image/heic': 'heic',
        'image/heif': 'heif',
        'image/avif': 'avif',
        'image/tiff': 'tiff',
        'image/bmp': 'bmp',
      }[mimeType.toLowerCase()] ??
      'jpg';
}

/// Replace the extension of [name] with [ext]. Used when re-encoding a picked
/// image to JPEG so the filename matches the bytes we actually send.
String _withExtension(String name, String ext) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? '${name.substring(0, dot)}.$ext' : '$name.$ext';
}

Future<Size?> _decodeImageSize(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    return Size(descriptor.width.toDouble(), descriptor.height.toDouble());
  } catch (_) {
    return null;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}
