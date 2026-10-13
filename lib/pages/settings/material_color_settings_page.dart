import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/material_color_provider.dart';
import '../../theme/material_theme.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/max_content_width.dart';

const _themeColors = [
  (label: '蓝色', color: defaultMaterialSeedColor),
  (label: '紫色', color: Color(0xFF8B5CF6)),
  (label: '青色', color: Color(0xFF008577)),
  (label: '绿色', color: Color(0xFF3C8D40)),
  (label: '粉色', color: Color(0xFFBA4C7E)),
  (label: '橙色', color: Color(0xFFE07B36)),
  (label: '蓝灰', color: Color(0xFF4B7399)),
  (label: '棕色', color: Color(0xFF8A6D52)),
];

class MaterialColorSettingsPage extends ConsumerWidget {
  const MaterialColorSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(materialColorSettingsProvider);
    final schemes = ref.watch(materialColorSchemesProvider);
    final system = ref.watch(systemMaterialColorsProvider);
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      extendBodyBehindAppBar: true,
      appBar: buildFloatingAppBar(title: const Text('配色')),
      body: MaxContentWidth(
        maxWidth: 600,
        child: Builder(
          builder: (context) => ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              MediaQuery.paddingOf(context).top + 16,
              16,
              MediaQuery.paddingOf(context).bottom + 24,
            ),
            children: [
              Text('配色预览', style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _SchemePreview(scheme: schemes.light)),
                  const SizedBox(width: 12),
                  Expanded(child: _SchemePreview(scheme: schemes.dark)),
                ],
              ),
              const SizedBox(height: 24),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('跟随系统配色'),
                subtitle: Text(
                  !settings.followSystem
                      ? '使用下方选择的主题色'
                      : system.isLoading
                      ? '正在读取系统配色'
                      : system.asData?.value != null
                      ? '使用系统壁纸或强调色'
                      : '系统未提供配色，使用所选主题色',
                ),
                value: settings.followSystem,
                onChanged: (value) => ref
                    .read(materialColorSettingsProvider.notifier)
                    .setFollowSystem(value),
              ),
              const SizedBox(height: 16),
              Text('主题色', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                '选择颜色即可切换到手动配色',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final choice in _themeColors)
                    ChoiceChip(
                      label: Text(choice.label),
                      avatar: _ColorDot(color: choice.color),
                      selected:
                          !settings.followSystem &&
                          settings.seedColor == choice.color,
                      onSelected: (_) => ref
                          .read(materialColorSettingsProvider.notifier)
                          .setSeedColor(choice.color),
                    ),
                ],
              ),
              const SizedBox(height: 24),
              _BackgroundChoices(
                brightness: Brightness.light,
                selected: settings.lightBackground,
                onChanged: (value) => ref
                    .read(materialColorSettingsProvider.notifier)
                    .setBackground(Brightness.light, value),
              ),
              const SizedBox(height: 24),
              _BackgroundChoices(
                brightness: Brightness.dark,
                selected: settings.darkBackground,
                onChanged: (value) => ref
                    .read(materialColorSettingsProvider.notifier)
                    .setBackground(Brightness.dark, value),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BackgroundChoices extends StatelessWidget {
  const _BackgroundChoices({
    required this.brightness,
    required this.selected,
    required this.onChanged,
  });

  final Brightness brightness;
  final MaterialBackground selected;
  final ValueChanged<MaterialBackground> onChanged;

  @override
  Widget build(BuildContext context) {
    final dark = brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          dark ? '深色背景' : '浅色背景',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final background in MaterialBackground.values)
              ChoiceChip(
                label: Text(switch (background) {
                  MaterialBackground.tonal => '随主题色',
                  MaterialBackground.pure => dark ? '纯黑' : '纯白',
                  MaterialBackground.soft => dark ? '极深灰' : '淡米白',
                }),
                avatar: background == MaterialBackground.tonal
                    ? const Icon(Icons.palette_outlined, size: 20)
                    : _ColorDot(color: background.colorFor(brightness)!),
                selected: selected == background,
                onSelected: (_) => onChanged(background),
              ),
          ],
        ),
      ],
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 20,
    height: 20,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
  );
}

class _SchemePreview extends StatelessWidget {
  const _SchemePreview({required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final preview = buildMaterialTheme(scheme.brightness, colorScheme: scheme);
    Widget bubble(String text, Color fill, Color foreground) => Container(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Text(
        text,
        style: preview.textTheme.bodySmall?.copyWith(color: foreground),
      ),
    );
    return Theme(
      data: preview,
      child: Card.outlined(
        margin: EdgeInsets.zero,
        color: scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                scheme.brightness == Brightness.light ? '浅色' : '深色',
                style: preview.textTheme.labelLarge?.copyWith(
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: bubble(
                  '你好',
                  scheme.surfaceContainerHigh,
                  scheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: bubble(
                  '一起聊聊',
                  scheme.primaryContainer,
                  scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _ColorDot(color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Matter',
                      style: preview.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
