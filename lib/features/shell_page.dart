import 'package:flutter/material.dart';

import '../core/widgets/glass_nav_bar.dart';
import '../core/widgets/ambient_background.dart';
import 'library/library_page.dart';
import 'settings/settings_page.dart';
import 'shadowing/shadowing_page.dart';
import 'stats/stats_page.dart';
import 'vocab/vocab_page.dart';

/// 应用主框架：环境光斑背景 + 页面区 + 悬浮玻璃导航
class ShellPage extends StatefulWidget {
  const ShellPage({super.key});

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage> {
  int _index = 0;

  static const _items = [
    GlassNavBarItem(icon: Icons.auto_stories_rounded, label: '内容库'),
    GlassNavBarItem(icon: Icons.mic_rounded, label: '跟读'),
    GlassNavBarItem(icon: Icons.insights_rounded, label: '统计'),
    GlassNavBarItem(icon: Icons.menu_book_rounded, label: '生词本'),
    GlassNavBarItem(icon: Icons.tune_rounded, label: '设置'),
  ];

  static const _pages = [
    LibraryPage(),
    ShadowingPage(),
    StatsPage(),
    VocabPage(),
    SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBody: true,
        body: IndexedStack(index: _index, children: _pages),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: GlassNavBar(
              items: _items,
              currentIndex: _index,
              onTap: (i) => setState(() => _index = i),
            ),
          ),
        ),
      ),
    );
  }
}
