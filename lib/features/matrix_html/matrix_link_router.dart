import 'package:url_launcher/url_launcher.dart';

typedef MatrixLinkHandler = Future<void> Function(Uri uri);

class MatrixLinkRouter {
  const MatrixLinkRouter();

  Future<void> open(Uri uri) async {
    if (!const {'http', 'https', 'mailto', 'matrix'}.contains(uri.scheme)) {
      return;
    }
    await launchUrl(uri, mode: LaunchMode.platformDefault);
  }
}
