import 'package:url_launcher/url_launcher.dart';

typedef MatrixLinkHandler = Future<void> Function(Uri uri);

const matrixUserIdPatternSource =
    r'@[!-9;-~]+:(?:\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.-]+)(?::[0-9]{1,5})?';

final _matrixUserIdPattern = RegExp('^$matrixUserIdPatternSource\$');
final _matrixUserIdPort = RegExp(r':([0-9]{1,5})$');

bool isMatrixUserId(String value) {
  if (!_matrixUserIdPattern.hasMatch(value)) return false;
  final serverName = value.substring(value.indexOf(':') + 1);
  final port = _matrixUserIdPort.firstMatch(serverName)?.group(1);
  return port == null || int.parse(port) <= 65535;
}

class MatrixLinkRouter {
  const MatrixLinkRouter();

  Future<void> open(Uri uri) async {
    if (matrixUserIdFromUri(uri) != null) return;
    if (!const {'http', 'https', 'mailto', 'matrix'}.contains(uri.scheme)) {
      return;
    }
    await launchUrl(uri, mode: LaunchMode.platformDefault);
  }
}

String? matrixUserIdFromUri(Uri uri) {
  String? candidate;
  if ((uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.toLowerCase() == 'matrix.to') {
    try {
      candidate = Uri.decodeComponent(
        uri.fragment,
      ).replaceFirst(RegExp(r'^/'), '').split('?').first;
    } on FormatException {
      return null;
    }
  } else if (uri.scheme == 'matrix' && uri.pathSegments.length >= 2) {
    final type = uri.pathSegments.first;
    if (type == 'u' || type == 'user') {
      candidate = '@${uri.pathSegments[1]}';
    }
  }
  if (candidate == null || !isMatrixUserId(candidate)) {
    return null;
  }
  return candidate;
}

String matrixMentionLabel(String userId, String? displayName) {
  final name = displayName?.trim();
  if (name == null || name.isEmpty || name == userId) return userId;
  return name.startsWith('@') ? name : '@$name';
}
