import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'liquid_glass.dart';
import '../theme/app_surface.dart';

class GlassNavBarItem {
  final IconData icon;
  final String label;

  const GlassNavBarItem({required this.icon, required this.label});
}

/// 悬浮的玻璃底部导航条
class GlassNavBar extends StatelessWidget {
  const GlassNavBar({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
  });

  final List<GlassNavBarItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return LiquidGlass(
      borderRadius: const BorderRadius.all(Radius.circular(30)),
      blurSigma: 44,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: List.generate(items.length, (i) {
          final selected = i == currentIndex;
          return Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onTap(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      items[i].icon,
                      size: 23,
                      color: selected
                          ? AppColors.primary
                          : AppSurface.textTertiary(context),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      items[i].label,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight:
                            selected ? FontWeight.w500 : FontWeight.w300,
                        color: selected
                            ? AppColors.primary
                            : AppSurface.textTertiary(context),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
