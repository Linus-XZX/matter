import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class AppAvatar extends StatelessWidget {
  final double size;
  final String? url;
  final String fallback;
  final double radius;

  const AppAvatar({
    super.key,
    this.size = 52,
    this.url,
    required this.fallback,
    this.radius = AppRadii.content,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: url != null
          ? Image.network(url!, fit: BoxFit.cover)
          : Center(
              child: Text(
                _initials,
                style: TextStyle(
                  color: AppColors.primary,
                  fontSize: size * 0.38,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
    );
  }

  String get _initials {
    final parts = fallback.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return fallback.isNotEmpty ? fallback[0].toUpperCase() : '?';
  }
}
