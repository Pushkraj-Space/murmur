import 'dart:convert';

import 'package:murmur_protocol/murmur_protocol.dart';
import 'package:murmur_protocol/testing.dart';

/// Host code written only against the runtime interfaces: it captures the
/// first two frames from the first discovered source.
Future<List<AudioFrame>> captureSyntheticClip(VoiceConnector connector) async {
  final source = await connector.discoverSources().first;
  final session = await connector.connect(source);
  try {
    final clip = session.frames.take(2).toList();
    await session.start();
    return await clip;
  } finally {
    await session.close();
  }
}

Future<void> main() async {
  final clip = await captureSyntheticClip(FakeVoiceConnector());
  for (final frame in clip) {
    final bytes = base64Decode(frame.payloadBase64).length;
    print(
      'frame ${frame.sequence} at ${frame.monotonicTimeUs} us: $bytes bytes',
    );
  }
}
