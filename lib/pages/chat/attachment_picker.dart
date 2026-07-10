import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
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

  /// Maximum bytes for non-image attachments (video / arbitrary file).
  static const int _maxFileBytes = 256 * 1024 * 1024; // 256 MB
  /// Longer edge cap for image downscaling (restores the old 4096px cap that
  /// the mandatory-editor flow used to enforce, and bounds upload memory).
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

    if (asset.type == AssetType.video) {
      final len = await file.length();
      if (len > _maxFileBytes) {
        throw '视频超过 ${_maxFileBytes ~/ 1024 ~/ 1024}MB 限制';
      }
      final bytes = await file.readAsBytes();
      final size = asset.size;
      await rust.sendVideoMessage(
        roomId: widget.roomId,
        videoData: bytes,
        filename: filename,
        width: size.width.round(),
        height: size.height.round(),
        durationMs: asset.videoDuration.inMilliseconds,
        size: bytes.length,
        mimeType: _guessMime(filename),
      );
      return;
    }

    final mime = _guessMime(filename);
    if (mime != null && mime.startsWith('image/')) {
      // Downscale via the native compressor (handles HEIC, low peak memory)
      // before loading full-res bytes into the FRB buffer.
      Uint8List bytes;
      try {
        final compressed = await FlutterImageCompress.compressWithFile(
          file.path,
          minWidth: _maxImageEdge,
          minHeight: _maxImageEdge,
          quality: _maxImageQuality,
          format: CompressFormat.jpeg,
        );
        bytes = compressed ?? await file.readAsBytes();
      } catch (_) {
        // Compressor can't handle some formats (e.g. exotic raw); send the
        // original rather than dropping the whole send.
        bytes = await file.readAsBytes();
      }
      final finalName = _withExtension(filename, 'jpg');
      final dim = await _decodeImageSize(bytes);
      await rust.sendImageMessage(
        roomId: widget.roomId,
        imageData: bytes,
        filename: finalName,
        width: dim?.width.round(),
        height: dim?.height.round(),
      );
    } else {
      final len = await file.length();
      if (len > _maxFileBytes) {
        throw '文件超过 ${_maxFileBytes ~/ 1024 ~/ 1024}MB 限制';
      }
      final bytes = await file.readAsBytes();
      await rust.sendFileMessage(
        roomId: widget.roomId,
        fileData: bytes,
        filename: filename,
        mimeType: mime,
        size: bytes.length,
      );
    }
  }

  Future<void> _sendXFiles(List<XFile> files) => _runBatch(
    files
        .map(
          (f) =>
              () => _sendSingleXFile(f),
        )
        .toList(),
    files,
  );

  Future<void> _sendSingleXFile(XFile f) async {
    final len = await f.length();
    if (len > _maxFileBytes) {
      throw '文件超过 ${_maxFileBytes ~/ 1024 ~/ 1024}MB 限制';
    }
    final mime = _guessMime(f.name) ?? f.mimeType;
    if (mime != null && mime.startsWith('image/')) {
      final original = await f.readAsBytes();
      Uint8List bytes;
      try {
        bytes = await FlutterImageCompress.compressWithList(
          original,
          minWidth: _maxImageEdge,
          minHeight: _maxImageEdge,
          quality: _maxImageQuality,
          format: CompressFormat.jpeg,
        );
      } catch (_) {
        bytes = original;
      }
      final dim = await _decodeImageSize(bytes);
      await rust.sendImageMessage(
        roomId: widget.roomId,
        imageData: bytes,
        filename: _withExtension(f.name, 'jpg'),
        width: dim?.width.round(),
        height: dim?.height.round(),
      );
    } else {
      final bytes = await f.readAsBytes();
      await rust.sendFileMessage(
        roomId: widget.roomId,
        fileData: bytes,
        filename: f.name,
        mimeType: f.mimeType,
        size: bytes.length,
      );
    }
  }

  Future<void> _sendEditedImage(Uint8List bytes) => _runBatch([
    () async {
      final filename = 'edited_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final imageSize = await _decodeImageSize(bytes);
      await rust.sendImageMessage(
        roomId: widget.roomId,
        imageData: bytes,
        filename: filename,
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
          await _finishBatch(presentation, sent, e);
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
      await _finishBatch(presentation, sent, null);
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  /// Best-effort refresh + completion callback. A refresh error is swallowed
  /// (it does not invalidate already-sent messages).
  Future<void> _finishBatch(
    MessageSendPresentation presentation,
    int sent,
    Object? partialFailure,
  ) async {
    try {
      await widget.onRefresh(widget.roomId);
    } catch (_) {
      // Refresh is best-effort; never surface as a send failure.
    }
    if (!mounted) return;
    widget.onMessageSent(presentation, false);
    if (partialFailure == null && mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final titles = const {
      AttachmentTab.media: '图片 / 视频',
      AttachmentTab.file: '文件',
      AttachmentTab.poll: '投票',
      AttachmentTab.location: '位置',
    };
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.onBackground,
        elevation: 0,
        title: Text(titles[_tab]!),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: Stack(
        children: [
          switch (_tab) {
            AttachmentTab.media =>
              photoManagerSupported
                  ? _MediaTabBody(
                      isSending: _isSending,
                      onSendAssets: _sendMediaAssets,
                      onOpenEditor: (bytes) async {
                        final edited = await Navigator.of(context)
                            .push<Uint8List>(
                              MaterialPageRoute(
                                fullscreenDialog: true,
                                builder: (_) =>
                                    ChatImageEditorPage(imageBytes: bytes),
                              ),
                            );
                        if (edited != null && mounted) {
                          await _sendEditedImage(edited);
                        }
                      },
                    )
                  : _MediaFallback(onSendFiles: _sendXFiles),
            AttachmentTab.file => _FileTabBody(
              isSending: _isSending,
              onSendFiles: _sendXFiles,
            ),
            AttachmentTab.poll => _PollTabBody(
              isSending: _isSending,
              onSendPoll: _sendPoll,
            ),
            AttachmentTab.location => _LocationTabBody(
              isSending: _isSending,
              onSendLocation: _sendLocation,
            ),
          },
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _FrostedTabBar(
              tab: _tab,
              onTabChanged: (t) => setState(() => _tab = t),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Frosted-glass mode bar ────────────────────────────────────────────

class _FrostedTabBar extends StatelessWidget {
  final AttachmentTab tab;
  final ValueChanged<AttachmentTab> onTabChanged;

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
                  onTap: () => onTabChanged(item.tab),
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
  final VoidCallback onTap;

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

class _MediaTabBody extends StatefulWidget {
  final bool isSending;
  final Future<void> Function(List<AssetEntity> assets) onSendAssets;
  final Future<void> Function(Uint8List bytes) onOpenEditor;

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
    if (_fetchingMore || _album == null) return;
    final total = await _album!.assetCountAsync;
    if (_assets.length >= total) return;
    setState(() => _fetchingMore = true);
    try {
      final next = await _album!.getAssetListPaged(
        page: _assets.length ~/ 100,
        size: 100,
      );
      if (!mounted) return;
      setState(() => _assets.addAll(next));
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
    final file = await asset.originFile;
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    await widget.onOpenEditor(bytes);
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
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(2, 2, 2, 96),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
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
                  onTap: isVideo
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
                          borderRadius: BorderRadius.circular(selected ? 8 : 0),
                          child: _AssetThumbnail(asset: asset),
                        ),
                      ),
                      Positioned(
                        top: 4,
                        right: 4,
                        child: GestureDetector(
                          onTap: () => _toggleSelect(asset),
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
  final Future<void> Function(List<XFile> files) onSendFiles;

  const _MediaFallback({required this.onSendFiles});

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
    final files = await openFiles(acceptedTypeGroups: _groups);
    if (files.isEmpty) return;
    setState(() => _picked.addAll(files));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
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
                  OutlinedButton(
                    onPressed: _pick,
                    child: const Text('选择图片 / 视频'),
                  ),
                  const SizedBox(height: 12),
                  for (final f in _picked)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        f.name,
                        style: const TextStyle(
                          color: AppColors.onSurface,
                          fontSize: 13,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (_picked.isNotEmpty)
          _SendBar(
            count: _picked.length,
            isSending: false,
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
    final files = await openFiles();
    if (files.isEmpty) return;
    setState(() => _picked = files);
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
                          onPressed: _pick,
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
                        onPressed: () =>
                            setState(() => _picked.removeAt(index)),
                      ),
                    );
                  },
                ),
        ),
        if (_picked.isNotEmpty)
          _SendBar(
            count: _picked.length,
            isSending: widget.isSending,
            onSend: () => widget.onSendFiles(List.of(_picked)),
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
    return valid >= 1;
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
                          onPressed: () {
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
                onPressed: _answers.length >= 20
                    ? null
                    : () =>
                          setState(() => _answers.add(TextEditingController())),
                icon: const Icon(Icons.add_rounded, color: AppColors.primary),
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
                onChanged: (v) => setState(() => _disclosed = v),
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

  String get _geoUri {
    final lat = _lat.text.trim();
    final lng = _lng.text.trim();
    final latVal = double.tryParse(lat);
    final lngVal = double.tryParse(lng);
    if (latVal == null ||
        lngVal == null ||
        latVal.abs() > 90 ||
        lngVal.abs() > 180) {
      return '';
    }
    return 'geo:$latVal,$lngVal';
  }

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
    // Common documents
    'pdf': 'application/pdf',
    'txt': 'text/plain',
    'zip': 'application/zip',
  }[ext];
}

/// Replace the extension of [name] with [ext]. Used when re-encoding a picked
/// image to JPEG so the filename matches the bytes we actually send.
String _withExtension(String name, String ext) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? '${name.substring(0, dot)}.$ext' : '$name.$ext';
}

Future<Size?> _decodeImageSize(Uint8List bytes) async {
  try {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromList(bytes, completer.complete);
    final image = await completer.future;
    final size = Size(image.width.toDouble(), image.height.toDouble());
    image.dispose();
    return size;
  } catch (_) {
    return null;
  }
}
