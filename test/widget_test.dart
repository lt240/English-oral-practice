import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ted_companion/core/widgets/liquid_glass.dart';

void main() {
  testWidgets('LiquidGlass 渲染其子内容', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: LiquidGlass(
            child: Text('玻璃卡片'),
          ),
        ),
      ),
    );

    expect(find.text('玻璃卡片'), findsOneWidget);
    // 强模糊层存在（① Deep Blur）
    expect(find.byType(BackdropFilter), findsOneWidget);
  });
}
