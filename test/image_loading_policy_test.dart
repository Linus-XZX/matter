import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/image_loading_policy.dart';

void main() {
  test('original loading uses byte limits and recognizes GIF MIME types', () {
    expect(shouldAutoLoadOriginal(fileSize: autoOriginalImageBytes), isTrue);
    expect(
      shouldAutoLoadOriginal(fileSize: autoOriginalImageBytes + 1),
      isFalse,
    );
    expect(
      shouldAutoLoadOriginal(
        fileSize: autoOriginalGifBytes,
        mimeType: 'IMAGE/GIF; charset=binary',
      ),
      isTrue,
    );
    expect(
      shouldAutoLoadOriginal(
        fileSize: autoOriginalGifBytes + 1,
        mimeType: 'image/gif',
      ),
      isFalse,
    );
    expect(
      shouldAutoLoadOriginal(
        fileSize: autoOriginalGifBytes,
        filename: 'animation.GIF',
      ),
      isTrue,
    );
    for (final size in [null, 0, -1]) {
      expect(
        shouldAutoLoadOriginal(fileSize: size, mimeType: 'image/gif'),
        isFalse,
      );
    }
  });
}
