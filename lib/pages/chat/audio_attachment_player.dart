import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import 'media_preparation.dart';
import 'chat_media_source.dart';
import 'media_playback.dart';
import 'prepared_media_source.dart';

/// Audio attachments load only when played; their file download stays available.
class AudioAttachmentPlayer extends ConsumerStatefulWidget {
  final String? url;
  final String? mediaSourceJson;
  final String filename;
  final Color foreground;

  const AudioAttachmentPlayer({
    super.key,
    required this.url,
    required this.mediaSourceJson,
    required this.filename,
    required this.foreground,
  });

  @override
  ConsumerState<AudioAttachmentPlayer> createState() =>
      _AudioAttachmentPlayerState();
}

class _AudioAttachmentPlayerState extends ConsumerState<AudioAttachmentPlayer>
    with WidgetsBindingObserver {
  MediaPlayback? _playback;
  PreparedMediaSource? _source;
  bool _loading = false;
  bool _failed = false;
  int _generation = 0;
  MediaPreparation? _preparation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ref.listenManual(
      currentUserProvider.select((user) => (user?.id, user?.homeserver)),
      (previous, next) {
        _reset();
        if (mounted) setState(() {});
      },
    );
    ref.listenManual(sessionReadyProvider, (previous, next) {
      if (previous == true && !next) {
        _reset();
        if (mounted) setState(() {});
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_playback?.pause());
    }
  }

  @override
  void didUpdateWidget(covariant AudioAttachmentPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.mediaSourceJson != widget.mediaSourceJson) {
      _reset();
    }
  }

  void _reset() {
    _generation++;
    _preparation?.cancel();
    _preparation = null;
    unawaited(_release(_playback, _source));
    _playback = null;
    _source = null;
    _loading = false;
    _failed = false;
  }

  Future<void> _togglePlayback() async {
    if (_loading) return;
    final playback = _playback;
    if (playback != null && playback.error == null) {
      await (playback.isPlaying ? playback.pause() : playback.play());
      return;
    }
    _reset();
    final generation = _generation;
    final preparation = _preparation = MediaPreparation();
    setState(() => _loading = true);
    MediaPlayback? next;
    PreparedMediaSource? source;
    try {
      source = await prepareChatMediaSource(
        ref: ref,
        url: widget.url,
        mediaSourceJson: widget.mediaSourceJson,
        filename: widget.filename,
        preparation: preparation,
      );
      if (!mounted || generation != _generation) {
        await source.cleanup();
        return;
      }
      next = MediaPlayback();
      await next.open(source.media);
      if (!mounted || generation != _generation) {
        await _release(next, source);
        return;
      }
      setState(() {
        _playback = next;
        _source = source;
        _loading = false;
      });
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (lifecycle != AppLifecycleState.paused &&
          lifecycle != AppLifecycleState.detached) {
        await next.play();
      }
    } catch (_) {
      await _release(next, source);
      if (mounted && generation == _generation) {
        setState(() {
          _playback = null;
          _source = null;
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  Future<void> _release(
    MediaPlayback? playback,
    PreparedMediaSource? source,
  ) async {
    try {
      await playback?.close();
    } finally {
      await source?.cleanup();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _reset();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _playback ?? const AlwaysStoppedAnimation(0),
    builder: (context, child) {
      final playback = _playback;
      final duration = playback?.duration.inMilliseconds ?? 0;
      final position = (playback?.position.inMilliseconds ?? 0).clamp(
        0,
        duration,
      );
      final failed = _failed || playback?.error != null;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                IconButton(
                  tooltip: failed
                      ? '重试播放'
                      : playback?.isPlaying == true
                      ? '暂停音频'
                      : '播放音频',
                  onPressed: _togglePlayback,
                  color: widget.foreground,
                  icon: Icon(
                    playback?.isPlaying == true
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                  ),
                ),
              Expanded(
                child: Slider(
                  value: position.toDouble(),
                  max: duration > 0 ? duration.toDouble() : 1,
                  onChanged: duration > 0 && !failed
                      ? (value) => playback?.seek(
                          Duration(milliseconds: value.round()),
                        )
                      : null,
                ),
              ),
              Text(
                '${_time(playback?.position ?? Duration.zero)} / ${_time(playback?.duration ?? Duration.zero)}',
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: widget.foreground),
              ),
            ],
          ),
          if (failed)
            Text(
              '无法播放此音频',
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: widget.foreground),
            ),
        ],
      );
    },
  );
}

String _time(Duration value) =>
    '${value.inMinutes}:${value.inSeconds.remainder(60).toString().padLeft(2, '0')}';
