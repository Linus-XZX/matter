import 'package:flutter/material.dart';

import 'glass.dart';

/// A standard toolbar over the page's fading surface. Its Scaffold must extend
/// the body behind the toolbar and reserve its height inside scrolling content.
AppBar buildFloatingAppBar({
  required Widget title,
  Widget? leading,
  List<Widget>? actions,
  PreferredSizeWidget? bottom,
  double toolbarHeight = kToolbarHeight,
  double? titleSpacing,
  bool automaticallyImplyLeading = true,
}) => AppBar(
  title: title,
  leading: leading,
  actions: actions,
  bottom: bottom,
  toolbarHeight: toolbarHeight,
  titleSpacing: titleSpacing,
  automaticallyImplyLeading: automaticallyImplyLeading,
  backgroundColor: Colors.transparent,
  surfaceTintColor: Colors.transparent,
  elevation: 0,
  scrolledUnderElevation: 0,
  flexibleSpace: const IgnorePointer(
    child: SizedBox.expand(child: TopFadeBlur(useShader: true)),
  ),
);
