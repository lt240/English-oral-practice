import 'dart:typed_data';

/// 麦克风 PCM16（little-endian）字节流 → Float32（-1.0 ~ 1.0）
/// sherpa-onnx 只接受 16kHz / 单声道 / Float32 采样。
Float32List pcm16BytesToSamples(List<int> bytes) {
  final count = bytes.length ~/ 2;
  final out = Float32List(count);
  final view = ByteData.sublistView(Uint8List.fromList(bytes));

  for (var i = 0; i < count; i++) {
    final s = view.getInt16(i * 2, Endian.little);
    out[i] = s / 32768.0;
  }
  return out;
}
