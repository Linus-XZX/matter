import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../widgets/app_avatar.dart';

/// Full-screen image preview with authentication support.
class ImagePreviewPage extends ConsumerWidget {
  final String imageUrl;

  const ImagePreviewPage({super.key, required this.imageUrl});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: Hero(
                tag: imageUrl,
                child: AuthenticatedImageMessage(
                  imageUrl: imageUrl,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: IconButton(
                  icon: const Icon(
                    Icons.close_rounded,
                    color: Colors.white,
                    size: 28,
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
