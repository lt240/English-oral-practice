import 'package:flutter/material.dart';

import 'liquid_glass.dart';

/// 可交互的液态玻璃按钮：按下时轻微收缩，像按压在玻璃表面
class LiquidGlassButton extends StatefulWidget {
  const LiquidGlassButton({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
    this.borderRadius = const BorderRadius.all(Radius.circular(22)),
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  final BorderRadius borderRadius;

  @override
  State<LiquidGlassButton> createState() => _LiquidGlassButtonState();
}

class _LiquidGlassButtonState extends State<LiquidGlassButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.94 : 1,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        child: LiquidGlass(
          borderRadius: widget.borderRadius,
          padding: widget.padding,
          child: widget.child,
        ),
      ),
    );
  }
}
