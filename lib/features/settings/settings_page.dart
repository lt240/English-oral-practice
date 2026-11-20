import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_surface.dart';
import '../../core/widgets/liquid_glass.dart';
import '../../data/speech_library.dart';
import '../../services/asr/model_installer.dart';
import '../../services/db/app_database.dart';
import '../../services/settings_controller.dart';

/// 设置：TTS 发音人 / 语速 / 主题 / 清除记录 / 离线模型状态
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final ModelInstaller _installer = ModelInstaller();

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除学习记录'),
        content: const Text('将清空全部跟读记录与统计数据，此操作不可恢复。确定继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空', style: TextStyle(color: AppColors.wrong)),
          ),
        ],
      ),
    );

    if (ok == true) {
      await AppDatabase.instance.clearAttempts();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('学习记录已清空')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsScope.of(context);

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 130),
        children: [
          Text('设置', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 24),

          // TTS 发音人
          LiquidGlass(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('TTS 发音人', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('女声')),
                    ButtonSegment(value: true, label: Text('男声')),
                  ],
                  selected: {settings?.voiceMale ?? false},
                  onSelectionChanged: (s) =>
                      settings?.setVoiceMale(s.first),
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                ),
                const SizedBox(height: 14),
                Text('朗读语速', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  '${(settings?.rate ?? 1.0).toStringAsFixed(1)}x（正常 1.0x）',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Slider(
                  value: settings?.rate ?? 1.0,
                  min: 0.5,
                  max: 2.0,
                  divisions: 15,
                  activeColor: AppColors.primary,
                  label: '${(settings?.rate ?? 1.0).toStringAsFixed(1)}x',
                  onChanged: settings?.setRate,
                ),
                Text(
                  '语速与发音人使用手机系统内置 TTS，免费且离线；'
                  '若某个性别不可选，说明当前手机未安装对应英文音声。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 外观
          LiquidGlass(
            child: Row(
              children: [
                Expanded(
                  child: Text('深色模式',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                Switch(
                  value: settings?.darkMode ?? false,
                  activeThumbColor: AppColors.primary,
                  onChanged: settings?.setDarkMode,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 复述设置
          LiquidGlass(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('复述录音时长上限',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  '单次复述最长录音时间，到点自动结束并评分。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 10),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 60, label: Text('60 秒')),
                    ButtonSegment(value: 90, label: Text('90 秒')),
                    ButtonSegment(value: 120, label: Text('120 秒')),
                  ],
                  selected: {settings?.retellMaxSeconds ?? 90},
                  onSelectionChanged: (s) =>
                      settings?.setRetellMaxSeconds(s.first),
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 学习目标
          LiquidGlass(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('每日目标', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text('统计页会显示目标完成度与连续打卡天数。',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 10),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 5, label: Text('5 句')),
                    ButtonSegment(value: 10, label: Text('10 句')),
                    ButtonSegment(value: 20, label: Text('20 句')),
                    ButtonSegment(value: 30, label: Text('30 句')),
                  ],
                  selected: {settings?.dailyGoal ?? 10},
                  onSelectionChanged: (s) => settings?.setDailyGoal(s.first),
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 识别精度（模型智能化）
          LiquidGlass(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('识别精度', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('精准识别档（base.en）'),
                  subtitle: Text(
                    '默认使用 tiny.en（快）。开启后优先用更大的 base.en，'
                    '需把 base.en-*.onnx 与 tokens 放入 assets/models/。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  value: settings?.accurateAsr ?? false,
                  activeThumbColor: AppColors.primary,
                  onChanged: (v) async {
                    final ready = await _installer.isReady(AsrTier.base);
                    if (!ready && v && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('base.en 模型文件未就绪，将保持使用 tiny.en'),
                      ));
                      return;
                    }
                    await settings?.setAccurateAsr(v);
                    if (mounted) setState(() {});
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('同音异形容错'),
                  subtitle: Text(
                    'write/right、can\'t/cannot 等识别差异按读对处理，'
                    '并对缩写、数字、连读做归一化，显著提升小模型判定准确度。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  value: settings?.fuzzyHomophones ?? true,
                  activeThumbColor: AppColors.primary,
                  onChanged: settings?.setFuzzyHomophones,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 清除记录
          GestureDetector(
            onTap: _confirmClear,
            child: LiquidGlass(
              child: Row(
                children: [
                  Expanded(
                    child: Text('清除学习记录',
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  const Icon(Icons.delete_outline_rounded,
                      color: AppColors.wrong, size: 22),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 离线模型状态
          LiquidGlass(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('离线模型状态',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                _ModelStatus(installer: _installer, tier: AsrTier.tiny),
                const SizedBox(height: 8),
                // base.en 模型未随包分发，显示静态说明而不是误导性的「缺失」红点。
                // 补齐 assets/models/base.en-* 后去掉 unavailableNote 即可恢复检查。
                _ModelStatus(
                  installer: _installer,
                  tier: AsrTier.base,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          LiquidGlass(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('隐私与内容', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(
                  '所有录音、识别与评分均在本机完成，不需要联网，也不会上传任何音频或学习数据。'
                  '麦克风权限仅用于跟读与复述录音，可在系统设置中随时关闭。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Text(
                  '内容库共 ${kSpeechLibrary.length} 篇；音频素材来自「TED音频」目录，'
                  '新增内容请把文件放进该目录并运行 tools/import_media.py。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ModelStatus extends StatelessWidget {
  const _ModelStatus({
    required this.installer,
    required this.tier,
  }) : unavailableNote = null;

  final ModelInstaller installer;
  final AsrTier tier;

  /// 非 null 表示该档模型未随包分发：显示灰色说明，跳过就绪检查。
  final String? unavailableNote;

  @override
  Widget build(BuildContext context) {
    if (unavailableNote != null) {
      return Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppSurface.textTertiary(context),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Whisper ${tier == AsrTier.tiny ? 'tiny.en' : 'base.en'}（int8）',
            style: const TextStyle(fontSize: 13.5),
          ),
          const Spacer(),
          Text(unavailableNote!, style: Theme.of(context).textTheme.bodySmall),
        ],
      );
    }

    return FutureBuilder<bool>(
      future: installer.isReady(tier),
      builder: (context, snapshot) {
        final ready = snapshot.data ?? false;
        final checking = snapshot.connectionState != ConnectionState.done;
        return Row(
          children: [
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: checking
                    ? AppSurface.textTertiary(context)
                    : ready
                        ? AppColors.correct
                        : AppColors.missed,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'Whisper ${tier == AsrTier.tiny ? 'tiny.en' : 'base.en'}（int8）',
              style: const TextStyle(fontSize: 13.5),
            ),
            const Spacer(),
            Text(
              checking ? '检查中' : (ready ? '已就绪' : '缺失'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        );
      },
    );
  }
}
