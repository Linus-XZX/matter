const autoOriginalImageBytes = 1024 * 1024;
const autoOriginalGifBytes = 8 * 1024 * 1024;

bool isGifImage({String? mimeType, String? filename}) =>
    mimeType?.split(';').first.trim().toLowerCase() == 'image/gif' ||
    filename?.toLowerCase().endsWith('.gif') == true;

bool shouldAutoLoadOriginal({
  int? fileSize,
  String? mimeType,
  String? filename,
}) {
  if (fileSize == null || fileSize <= 0) return false;
  final limit = isGifImage(mimeType: mimeType, filename: filename)
      ? autoOriginalGifBytes
      : autoOriginalImageBytes;
  return fileSize <= limit;
}
