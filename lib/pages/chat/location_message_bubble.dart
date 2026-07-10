import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../theme/app_theme.dart';

typedef LocationUriLauncher = Future<bool> Function(Uri uri);

({double latitude, double longitude})? _parseGeoPoint(String value) {
  if (!value.toLowerCase().startsWith('geo:')) return null;
  final payload = value.substring(4).split(RegExp(r'[;?]')).first;
  final parts = payload.split(',');
  if (parts.length < 2 || parts.length > 3) return null;
  final decimal = RegExp(r'^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$');
  if (parts.any((part) => !decimal.hasMatch(part))) return null;
  final latitude = double.tryParse(parts[0]);
  final longitude = double.tryParse(parts[1]);
  final altitude = parts.length == 3 ? double.tryParse(parts[2]) : null;
  if (latitude == null ||
      longitude == null ||
      !latitude.isFinite ||
      !longitude.isFinite ||
      (parts.length == 3 && (altitude == null || !altitude.isFinite)) ||
      latitude.abs() > 90 ||
      longitude.abs() > 180) {
    return null;
  }
  return (latitude: latitude, longitude: longitude);
}

/// Renders a received `m.location` and opens it in a maps application.
class LocationMessageBubble extends StatelessWidget {
  final String body;
  final String geoUri;
  final bool isMe;
  final Widget metadata;
  final double maxWidth;
  final LocationUriLauncher? launchUri;

  const LocationMessageBubble({
    super.key,
    required this.body,
    required this.geoUri,
    required this.isMe,
    required this.metadata,
    this.maxWidth = 240,
    this.launchUri,
  });

  Future<void> _open(BuildContext context) async {
    final point = _parseGeoPoint(geoUri);
    if (point == null) {
      _showError(context, '位置链接无效');
      return;
    }
    final launcher =
        launchUri ??
        (uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
    try {
      if (await launcher(Uri.parse(geoUri))) return;
    } catch (_) {
      // Browsers commonly reject geo: even though an HTTPS map works.
    }
    final fallback = Uri(
      scheme: 'https',
      host: 'www.openstreetmap.org',
      path: '/',
      queryParameters: {
        'mlat': point.latitude.toString(),
        'mlon': point.longitude.toString(),
      },
      fragment: 'map=16/${point.latitude}/${point.longitude}',
    );
    try {
      if (await launcher(fallback)) return;
      if (context.mounted) _showError(context, '无法打开地图');
    } catch (_) {
      if (context.mounted) _showError(context, '无法打开地图');
    }
  }

  void _showError(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final label = body.trim().isEmpty ? geoUri : body;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.content),
        child: Stack(
          children: [
            Material(
              color: isMe
                  ? AppColors.primary.withValues(alpha: 0.22)
                  : AppColors.surfaceVariant,
              child: InkWell(
                onTap: () => _open(context),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 22),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.location_on_rounded,
                        color: AppColors.primary,
                        size: 30,
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          label,
                          style: const TextStyle(
                            color: AppColors.onBackground,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(
                        Icons.open_in_new_rounded,
                        size: 18,
                        color: AppColors.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            metadata,
          ],
        ),
      ),
    );
  }
}
