import 'package:flutter/material.dart';

/// Keeps the Material navigation controls while moving one indicator with the
/// same position animation as the tab pages, including partial swipes.
class MaterialTabNavigationBar extends StatefulWidget {
  const MaterialTabNavigationBar({
    super.key,
    required this.position,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
  });

  final ValueNotifier<double> position;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NavigationDestination> destinations;

  @override
  State<MaterialTabNavigationBar> createState() =>
      _MaterialTabNavigationBarState();
}

class _MaterialTabNavigationBarState extends State<MaterialTabNavigationBar> {
  final _paintKey = GlobalKey();
  late final _iconKeys = List.generate(
    widget.destinations.length,
    (_) => GlobalKey(),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final barTheme = NavigationBarTheme.of(context);
    return Material(
      color: barTheme.backgroundColor ?? scheme.surfaceContainer,
      child: RepaintBoundary(
        child: CustomPaint(
          key: _paintKey,
          painter: _TabIndicatorPainter(
            position: widget.position,
            barKey: _paintKey,
            iconKeys: _iconKeys,
            color: barTheme.indicatorColor ?? scheme.secondaryContainer,
          ),
          child: NavigationBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            surfaceTintColor: Colors.transparent,
            indicatorColor: Colors.transparent,
            animationDuration: const Duration(milliseconds: 240),
            selectedIndex: widget.selectedIndex,
            onDestinationSelected: widget.onDestinationSelected,
            destinations: [
              for (var index = 0; index < widget.destinations.length; index++)
                NavigationDestination(
                  label: widget.destinations[index].label,
                  tooltip: widget.destinations[index].tooltip,
                  enabled: widget.destinations[index].enabled,
                  icon: SizedBox(
                    key: _iconKeys[index],
                    width: 24,
                    height: 24,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: KeyedSubtree(
                        key: ValueKey(widget.selectedIndex == index),
                        child: widget.selectedIndex == index
                            ? widget.destinations[index].selectedIcon ??
                                  widget.destinations[index].icon
                            : widget.destinations[index].icon,
                      ),
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

class _TabIndicatorPainter extends CustomPainter {
  _TabIndicatorPainter({
    required this.position,
    required this.barKey,
    required this.iconKeys,
    required this.color,
  }) : super(repaint: position);

  final ValueNotifier<double> position;
  final GlobalKey barKey;
  final List<GlobalKey> iconKeys;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final bar = barKey.currentContext!.findRenderObject()! as RenderBox;
    Offset iconCenter(GlobalKey key) {
      final icon = key.currentContext!.findRenderObject()! as RenderBox;
      return icon.localToGlobal(icon.size.center(Offset.zero), ancestor: bar);
    }

    // Use the laid-out icon centers so RTL, safe areas and enlarged labels
    // keep the indicator aligned with the actual Material destinations.
    final center = Offset.lerp(
      iconCenter(iconKeys.first),
      iconCenter(iconKeys.last),
      position.value / (iconKeys.length - 1),
    )!;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: center, width: 64, height: 32),
        const Radius.circular(16),
      ),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_TabIndicatorPainter oldDelegate) =>
      oldDelegate.position != position || oldDelegate.color != color;
}
