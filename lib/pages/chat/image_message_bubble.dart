import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import 'image_preview_page.dart';

class ImageMessageBubble extends StatelessWidget {
  final String imageUrl;
  final String timestamp;
  final bool isMe;

  const ImageMessageBubble({
    super.key,
    required this.imageUrl,
    required this.timestamp,
    required this.isMe,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ImagePreviewPage(imageUrl: imageUrl),
          ),
        );
      },
      child: Hero(
        tag: imageUrl,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.65,
            maxHeight: 280,
          ),
          decoration: BoxDecoration(
            color: isMe ? AppColors.primary.withValues(alpha: 0.3) : AppColors.surfaceElevated,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(AppRadii.content),
              topRight: const Radius.circular(AppRadii.content),
              bottomLeft: Radius.circular(isMe ? AppRadii.content : AppRadii.tag),
              bottomRight: Radius.circular(isMe ? AppRadii.tag : AppRadii.content),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            alignment: Alignment.bottomRight,
            children: [
              Image.network(
                imageUrl,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                loadingBuilder: (context, child, progress) {
                  if (progress == null) return child;
                  return Container(
                    color: isMe ? AppColors.primary.withValues(alpha: 0.15) : AppColors.surface,
                    child: const Center(
                      child: CircularProgressIndicator(
                        color: AppColors.primary,
                        strokeWidth: 2,
                      ),
                    ),
                  );
                },
                errorBuilder: (context, error, stackTrace) {
                  return Container(
                    color: isMe ? AppColors.primary.withValues(alpha: 0.15) : AppColors.surface,
                    child: const Center(
                      child: Icon(
                        Icons.broken_image_rounded,
                        color: AppColors.onSurfaceVariant,
                        size: 40,
                      ),
                    ),
                  );
                },
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.5),
                    ],
                  ),
                ),
                child: Text(
                  timestamp,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 10.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
