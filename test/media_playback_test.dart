import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:matter/pages/chat/media_playback.dart';

class _Player extends PlatformPlayer {
  _Player() : super(configuration: const PlayerConfiguration());
  final calls = <String>[];
  bool? autoplay;
  bool disposed = false;
  Completer<void>? disposeBarrier;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    autoplay = play;
  }

  @override
  Future<void> setVolume(double volume) async {
    state = state.copyWith(volume: volume);
    volumeController.add(volume);
  }

  @override
  Future<void> play() async {
    calls.add('play');
    state = state.copyWith(playing: true);
    playingController.add(true);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    state = state.copyWith(playing: false);
    playingController.add(false);
  }

  @override
  Future<void> seek(Duration duration) async {
    calls.add('seek:${duration.inSeconds}');
    state = state.copyWith(position: duration, completed: false);
    positionController.add(duration);
  }

  void emitDimensionsAndError() {
    state = state.copyWith(width: 1080, height: 1920);
    widthController.add(1080);
    errorController.add('Unsupported media');
  }

  @override
  Future<void> dispose() async {
    await disposeBarrier?.future;
    disposed = true;
    await super.dispose();
  }
}

void main() {
  late _Player platform;
  late MediaPlayback playback;

  setUp(() {
    platform = _Player();
    playback = MediaPlayback(player: Player(platformPlayer: platform));
  });
  tearDown(() => playback.close());

  test(
    'opens paused and translates normalized volume to media_kit percent',
    () async {
      await playback.open(Media('file:///sample.mp4'));
      expect(platform.autoplay, isFalse);
      await playback.setVolume(0.35);
      expect(platform.state.volume, 35);
      expect(playback.volume, 0.35);
      await playback.setVolume(0);
      expect(playback.volume, 0);
    },
  );

  test(
    'replays completed media from the start and supports pause and seek',
    () async {
      platform.state = platform.state.copyWith(completed: true);
      await playback.play();
      expect(platform.calls, ['seek:0', 'play']);
      await playback.pause();
      await playback.seek(const Duration(seconds: 12));
      expect(platform.calls, ['seek:0', 'play', 'pause', 'seek:12']);
    },
  );

  test('concurrent close calls both wait for native teardown', () async {
    final barrier = platform.disposeBarrier = Completer<void>();
    var firstDone = false;
    var secondDone = false;
    final first = playback.close().then((_) => firstDone = true);
    final second = playback.close().then((_) => secondDone = true);
    await Future<void>.delayed(Duration.zero);
    expect(firstDone, isFalse);
    expect(secondDone, isFalse);
    barrier.complete();
    await Future.wait([first, second]);
    expect(platform.disposed, isTrue);
  });

  test(
    'updates dimensions and runtime errors then releases subscriptions once',
    () async {
      var changes = 0;
      playback.addListener(() => changes++);
      platform.emitDimensionsAndError();
      await Future<void>.delayed(Duration.zero);
      expect(playback.aspectRatio, 1080 / 1920);
      expect(playback.error, 'Unsupported media');
      expect(changes, 2);
      await playback.close();
      await playback.close();
      expect(platform.disposed, isTrue);
    },
  );
}
