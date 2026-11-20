import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/liquid_glass.dart';
import '../../services/aligner.dart';
import '../../services/asr/model_installer.dart';
import '../../services/shadowing_recorder.dart';
import '../../core/theme/app_surface.dart';

/// 一条跟读结果：识别句 + （有参考句时）逐词对齐结果
class _Result {
  final RecognizedSegment segment;
  final List<AlignedWord>? aligned;
  final double? score; // 0~1，读对词数 / 原文词数

  const _Result({required this.segment, this.aligned, this.score});
}

/// 跟读模式：点麦克风开始，读一句 → 停顿 0.7s → 自动识别并反馈
class ShadowingPage extends StatefulWidget {
  const ShadowingPage({super.key});

  @override
  State<ShadowingPage> createState() => _ShadowingPageState();
}

class _ShadowingPageState extends State<ShadowingPage> {
  final ShadowingRecorder _recorder = ShadowingRecorder();
  final TextEditingController _refController = TextEditingController();
  final List<_Result> _results = [];
  AsrTier _tier = AsrTier.tiny;

  @override
  void initState() {
    super.initState();
    _recorder.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _toggle() async {
    if (_recorder.isListening) {
      await _recorder.stop();
      return;
    }
    if (_recorder.isInitializing) return; // 加载中忽略点击

    _results.clear();
    try {
      await _recorder.start(
        tier: _tier,
        silenceDuration: 0.7,
        onSegment: (seg) {
          if (!mounted) return;
          final refText = _refController.text.trim();
          _Result result;
          if (refText.isNotEmpty) {
            final aligned = WordAligner.alignSentence(
              reference: refText,
              recognized: seg.text,
            );
            final refCount = WordAligner.tokenize(refText).length;
            final correct = aligned
                .where((w) => w.verdict == WordVerdict.correct)
                .length;
            result = _Result(
              segment: seg,
              aligned: aligned,
              score: refCount == 0 ? null : correct / refCount,
            );
          } else {
            result = _Result(segment: seg);
          }
          setState(() => _results.add(result));
        },
      );
    } on MissingModelException catch (e) {
      if (mounted) _showMissingModel(e);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法开始：$e')),
        );
      }
    }
  }

  void _showMissingModel(MissingModelException e) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('离线模型未就绪'),
        content: Text(
          '${e.toString()}\n\n'
          '请在打包素材时把以下文件放入 assets/models/：\n'
          '· silero_vad.onnx\n'
          '· ${_tier == AsrTier.tiny ? 'tiny.en' : 'base.en'}-encoder.int8.onnx\n'
          '· ${_tier == AsrTier.tiny ? 'tiny.en' : 'base.en'}-decoder.int8.onnx\n'
          '· ${_tier == AsrTier.tiny ? 'tiny.en' : 'base.en'}-tokens.txt\n\n'
          '模型下载：\n${ModelInstaller.vadUrl}\n'
          '${_tier == AsrTier.tiny ? ModelInstaller.tinyEnUrl : ModelInstaller.baseEnUrl}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _recorder.removeListener(_onChanged);
    _recorder.dispose();
    _refController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String hint;
    if (_recorder.isInitializing) {
      hint = '正在加载离线模型…';
    } else if (_recorder.isListening) {
      hint = _recorder.isSpeaking ? '正在听你朗读…' : '停顿中，准备识别';
    } else {
      hint = '点击麦克风，读一句后停顿即可';
    }

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 130),
        children: [
          Text('跟读模式', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(hint, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 28),
          Center(
            child: _MicButton(
              state: _recorder.recorderState,
              speaking: _recorder.isSpeaking,
              onTap: _toggle,
            ),
          ),
          const SizedBox(height: 20),
          Center(
            child: SegmentedButton<AsrTier>(
              // base.en 模型未随包分发（assets/models 里只有 tiny.en 三件套），
              // 暂时禁用该档位，避免选中后抛 MissingModelException。
              // 补齐 base.en-* 三个文件后，把 enabled 改回 true 即可恢复。
              segments: const [
                ButtonSegment(value: AsrTier.tiny, label: Text('快速 tiny')),
                ButtonSegment(
                  value: AsrTier.base,
                  label: Text('标准 base（未随包）'),
                  enabled: false,
                ),
              ],
              selected: {_tier},
              onSelectionChanged: _recorder.isBusy
                  ? null
                  : (s) => setState(() => _tier = s.first),
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
          const SizedBox(height: 24),

          // 参考句：填入后即按绿/红/橙逐词反馈（后续由「聆听→跟读」自动带入）
          LiquidGlass(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: TextField(
              controller: _refController,
              enabled: !_recorder.isBusy,
              minLines: 1,
              maxLines: 3,
              style: const TextStyle(fontSize: 14),
              decoration: const InputDecoration(
                border: InputBorder.none,
                isDense: true,
                hintText: '参考句（可选）：填入要跟读的英文，得到逐词着色与句分',
                hintStyle: TextStyle(fontSize: 13),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 逐词反馈颜色图例
          const LiquidGlass(
            padding: EdgeInsets.all(16),
            child: Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _LegendDot(color: AppColors.correct, label: '读对'),
                _LegendDot(color: AppColors.wrong, label: '读错'),
                _LegendDot(color: AppColors.missed, label: '漏读 / 多读'),
                _LegendDot(color: AppColors.unread, label: '未读'),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 已识别句（最新在上）
          ..._results.reversed.map(_buildResultCard),
        ],
      ),
    );
  }

  Widget _buildResultCard(_Result result) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: LiquidGlass(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (result.score != null) ...[
              Row(
                children: [
                  Text(
                    '句分 ${(result.score! * 100).round()}%',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: result.score! >= 0.8
                          ? AppColors.correct
                          : result.score! >= 0.5
                              ? AppColors.primary
                              : AppColors.wrong,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${result.segment.start.toStringAsFixed(1)}s – ${result.segment.end.toStringAsFixed(1)}s',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _alignedText(result.aligned!),
              const SizedBox(height: 8),
              Text(
                '识别原文：${result.segment.text.isEmpty ? '（未识别到内容）' : result.segment.text}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ] else
              Text(
                result.segment.text.isEmpty
                    ? '（未识别到内容）'
                    : result.segment.text,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
          ],
        ),
      ),
    );
  }

  /// 逐词着色 RichText
  Widget _alignedText(List<AlignedWord> words) {
    final spans = <InlineSpan>[];

    for (var i = 0; i < words.length; i++) {
      final w = words[i];
      final Color color;
      final String label;
      switch (w.verdict) {
        case WordVerdict.correct:
          color = AppColors.correct;
          label = w.reference!;
        case WordVerdict.wrong:
          color = AppColors.wrong;
          label = w.reference!;
        case WordVerdict.missed:
          color = AppColors.missed;
          label = w.reference!;
        case WordVerdict.extra:
          color = AppColors.missed;
          label = w.spoken!;
      }
      spans.add(
        TextSpan(
          text: label,
          style: TextStyle(
            color: color,
            fontSize: 17,
            fontWeight: w.verdict == WordVerdict.correct
                ? FontWeight.w400
                : FontWeight.w500,
          ),
        ),
      );
      if (i < words.length - 1) {
        spans.add(const TextSpan(text: ' '));
      }
    }

    return RichText(text: TextSpan(children: spans));
  }
}

class _MicButton extends StatelessWidget {
  const _MicButton({
    required this.state,
    required this.speaking,
    required this.onTap,
  });

  final RecorderState state;
  final bool speaking;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final listening = state == RecorderState.listening;
    final initializing = state == RecorderState.initializing;
    final color = initializing
        ? AppSurface.textTertiary(context)
        : listening
            ? (speaking ? AppColors.wrong : AppColors.primary)
            : AppColors.primary;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        width: 92,
        height: 92,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: listening ? 0.9 : 0.82),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.35),
              blurRadius: speaking ? 44 : 24,
              spreadRadius: speaking ? 6 : 0,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: initializing
            ? const Padding(
                padding: EdgeInsets.all(30),
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            : Icon(
                listening ? Icons.stop_rounded : Icons.mic_rounded,
                color: Colors.white,
                size: 40,
              ),
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 12.5)),
      ],
    );
  }
}
