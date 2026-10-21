import 'package:flutter/material.dart';

import 'glass_surface.dart';
import 'photos_grid.dart';
import 'strings.dart';

/// The canonical segmented control: one raised glass capsule floating at the
/// bottom-center of the Photos page. Equal-width segments; the active segment
/// reads through label contrast plus a short bottom indicator — never a
/// per-segment filled background. See ui-design.md "Year/Month/Day Mode
/// Selector" and ui-liquid-glass.md "Canonical Segmented Style".
class ModeSelector extends StatelessWidget {
  const ModeSelector({
    super.key,
    required this.mode,
    required this.onChanged,
    this.glass = true,
  });

  final GroupMode mode;
  final ValueChanged<GroupMode> onChanged;
  final bool glass;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final scheme = Theme.of(context).colorScheme;
    // The capsule must give GlassSurface tight constraints: with the loose
    // ones from the Align, the 20% blur-area budget would measure the whole
    // stage instead of this surface, and the live glass could never engage.
    return SizedBox(
      height: 48,
      width: 264,
      child: GlassSurface(
        enabled: glass,
        live: true,
        radius: 24,
        child: Row(
          children: [
            for (final (value, label, key) in [
              (GroupMode.year, strings.modeYear, 'mode-year'),
              (GroupMode.month, strings.modeMonth, 'mode-month'),
              (GroupMode.day, strings.modeDay, 'mode-day'),
            ])
              Expanded(
                child: _Segment(
                  key: ValueKey(key),
                  label: label,
                  active: mode == value,
                  activeColor: scheme.onSurface,
                  inactiveColor: scheme.onSurface.withValues(alpha: .55),
                  indicatorColor: scheme.primary,
                  onTap: () => onChanged(value),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    super.key,
    required this.label,
    required this.active,
    required this.activeColor,
    required this.inactiveColor,
    required this.indicatorColor,
    required this.onTap,
  });

  final String label;
  final bool active;
  final Color activeColor;
  final Color inactiveColor;
  final Color indicatorColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: active,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 7),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 180),
                style: TextStyle(
                  fontSize: 13,
                  height: 1.2,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  color: active ? activeColor : inactiveColor,
                ),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(height: 6),
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 22,
                height: 3,
                decoration: BoxDecoration(
                  color: active
                      ? indicatorColor
                      : indicatorColor.withValues(alpha: 0),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
