import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'dictionary_popup.dart';

/// 可点词文本：普通 Text 的替代组件，文本中的英文单词可点击，
/// 点击后弹出词典弹窗；标点与空白不响应点击。
class TappableText extends StatefulWidget {
  const TappableText(
    this.text, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
  });

  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  State<TappableText> createState() => _TappableTextState();
}

class _TappableTextState extends State<TappableText> {
  /// 匹配英文单词（含撇号/连字符），其余字符作为普通 span
  static final RegExp _wordReg = RegExp(r"[A-Za-z][A-Za-z''\-]*");

  List<TapGestureRecognizer> _recognizers = const [];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers = const [];
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final recognizers = <TapGestureRecognizer>[];
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _wordReg.allMatches(widget.text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: widget.text.substring(last, m.start)));
      }
      final word = m.group(0)!;
      final recognizer = TapGestureRecognizer()
        ..onTap = () => DictionaryPopup.show(
              context,
              word,
              contextSentence: widget.text,
            );
      recognizers.add(recognizer);
      spans.add(TextSpan(text: word, recognizer: recognizer));
      last = m.end;
    }
    if (last < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(last)));
    }
    _recognizers = recognizers;
    return Text.rich(
      TextSpan(children: spans),
      style: widget.style,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
    );
  }
}
