import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class LiquidGlassContainer extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final double blurSigma;

  const LiquidGlassContainer({
    super.key,
    required this.child,
    this.borderRadius = AppRadii.surface,
    this.padding = const EdgeInsets.all(12),
    this.margin = EdgeInsets.zero,
    this.blurSigma = 12,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: margin,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: AppColors.glassBackground,
              borderRadius: BorderRadius.circular(borderRadius),
              border: Border.all(
                color: AppColors.glassBorder,
                width: 0.8,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}