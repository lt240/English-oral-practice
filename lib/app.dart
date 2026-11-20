import 'package:flutter/material.dart';

import 'core/theme/glass_theme.dart';
import 'features/shell_page.dart';
import 'services/settings_controller.dart';

class TedCompanionApp extends StatelessWidget {
  const TedCompanionApp({super.key, required this.settings});

  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    return SettingsScope(
      controller: settings,
      child: ListenableBuilder(
        listenable: settings,
        builder: (context, _) {
          return MaterialApp(
            title: '英语口语学习助手',
            debugShowCheckedModeBanner: false,
            theme: buildGlassTheme(),
            darkTheme: buildDarkGlassTheme(),
            themeMode: settings.themeMode,
            home: const ShellPage(),
          );
        },
      ),
    );
  }
}
