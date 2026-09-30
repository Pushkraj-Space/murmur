import 'dart:async';
import 'dart:convert';

import 'package:murmur_protocol/murmur_protocol.dart';
import 'package:test/test.dart';

import '../example/synthetic_tone_connector.dart';

void main() {
  late StreamController<void> ticks;
  late int nowUs;

  SyntheticToneConnector connector({Future<void> Function()? acquire}) =>
      SyntheticToneConnector(
        frameClock: (_) => ticks.stream,
        acquire: acquire,
        clockUs: () => nowUs,
      );

  Future<void> tick(int count) async {
    for (var i = 0; i < count; i++) {
      ticks.add(null);
    }
    await pumpEventQueue();
  }

  setUp(() {
    ticks = StreamController<void>();
    nowUs = 1000000;
  });

  // A never-listened controller's close() never completes, so do not await it.
  tearDown(() => unawaited(ticks.close()));

  test('discovers the synthetic source until the scan is cancelled', () async {
    final sources = await connector().discoverSources().take(1).toList();

    expect(sources.single.id, 'source-synthetic-tone');
    expect(sources.single.transport, VoiceSourceTransport.synthetic);
    expect(sources.single.capabilities, {VoiceSourceCapability.liveAudio});
  });

  test('connect returns an idle session and rejects unknown sources', () async {
    final session = await connector().connect(SyntheticToneConnector.source);
    expect(session.state, SessionState.idle);
    expect(session.format, isNull);

    final unknown = VoiceSource(
      id: 'source-other',
      displayName: 'Other',
      transport: VoiceSourceTransport.synthetic,
    );
    await expectLater(
      connector().connect(unknown),
      throwsA(
        isA<VoiceError>().having((e) => e.code, 'code', 'connect_failed'),
      ),
    );
  });

  test('start reports starting then listening and negotiates PCM', () async {
    final session = await connector().connect(SyntheticToneConnector.source);
    final states = <SessionState>[];
    session.stateChanges.listen(states.add);

    await session.start();

    expect(states, [SessionState.starting, SessionState.listening]);
    expect(session.format!.toJson(), {
      'sampleRateHz': 16000,
      'channels': 1,
      'encoding': 'AUDIO_ENCODING_PCM_S16LE',
      'frameDurationMs': 20,
    });
    await session.close();
  });

  test('frames are deterministic PCM with sample-clock timestamps', () async {
    Future<List<AudioFrame>> capture() async {
      final session = await connector().connect(SyntheticToneConnector.source);
      await session.start();
      final frames = <AudioFrame>[];
      session.frames.listen(frames.add);
      await tick(3);
      await session.stop();
      return frames;
    }

    final first = await capture();
    ticks = StreamController<void>();
    final second = await capture();

    expect(first.map((f) => f.sequence), [
      BigInt.one,
      BigInt.two,
      BigInt.from(3),
    ]);
    // 20 ms frames advance by exactly 20000 us from the session start.
    expect(first.map((f) => f.monotonicTimeUs.toInt() - nowUs), [
      0,
      20000,
      40000,
    ]);
    // 16 kHz mono PCM S16LE for 20 ms is 320 samples, 640 bytes.
    expect(base64Decode(first.first.payloadBase64), hasLength(640));
    expect(
      second.map((f) => f.payloadBase64),
      first.map((f) => f.payloadBase64),
    );
    for (final frame in first) {
      expect(AudioFrame.fromJson(frame.toJson()).toJson(), frame.toJson());
    }
  });

  test('refuses an unsupported requested format', () async {
    final session = await connector().connect(SyntheticToneConnector.source);

    await expectLater(
      session.start(
        requestedFormat: AudioFormat(
          sampleRateHz: 48000,
          channels: 1,
          encoding: AudioEncoding.pcmS16le,
        ),
      ),
      throwsA(
        isA<VoiceError>().having((e) => e.code, 'code', 'format_unavailable'),
      ),
    );
    expect(session.state, SessionState.error);
    expect(session.error?.code, 'format_unavailable');
  });

  test('stop during startup cancels start and never listens', () async {
    final opened = Completer<void>();
    final session = await connector(
      acquire: () => opened.future,
    ).connect(SyntheticToneConnector.source);
    final states = <SessionState>[];
    session.stateChanges.listen(states.add);

    final start = session.start();
    final stop = session.stop();
    await expectLater(
      start,
      throwsA(isA<VoiceError>().having((e) => e.code, 'code', 'cancelled')),
    );
    await stop;
    opened.complete();
    await tick(2);

    expect(states, [SessionState.starting, SessionState.stopped]);
    expect(session.state, SessionState.stopped);
    expect(session.format, isNull);
    expect(await session.frames.toList(), isEmpty);
  });

  test('device loss ends the session with a retryable error', () async {
    final session =
        await connector().connect(SyntheticToneConnector.source)
            as SyntheticToneSession;
    await session.start();
    final framesDone = session.frames.toList();
    await tick(1);

    await session.simulateDeviceLoss();

    expect(session.state, SessionState.error);
    expect(session.error?.code, 'device_lost');
    expect(session.error?.retryable, isTrue);
    expect(await framesDone, hasLength(1));
    await tick(2);
  });

  test('buffers a bounded number of frames and drops the oldest', () async {
    final session =
        await connector().connect(SyntheticToneConnector.source)
            as SyntheticToneSession;
    await session.start();

    // No consumer yet: only the newest frameCapacity frames are kept.
    await tick(SyntheticToneSession.frameCapacity + 4);
    final frames = <AudioFrame>[];
    session.frames.listen(frames.add);
    await pumpEventQueue();

    expect(session.droppedFrames, 4);
    expect(frames, hasLength(SyntheticToneSession.frameCapacity));
    expect(frames.first.sequence, BigInt.from(5));
    await session.close();
  });

  test('stop and close share one cleanup and are terminal', () async {
    final session = await connector().connect(SyntheticToneConnector.source);
    await session.start();

    final first = session.stop(reason: 'done');
    final second = session.close();
    expect(identical(first, second), isTrue);
    await first;

    expect(session.state, SessionState.stopped);
    expect(() => session.start(), throwsStateError);
  });

  for (final trigger in [SessionState.starting, SessionState.listening]) {
    test('stop from a stateChanges listener on ${trigger.name} '
        'releases the frame clock', () async {
      var clockListened = false;
      var clockCancelled = false;
      final clock = StreamController<void>(
        onListen: () => clockListened = true,
        onCancel: () => clockCancelled = true,
      );
      final session = await SyntheticToneConnector(
        frameClock: (_) => clock.stream,
        clockUs: () => nowUs,
      ).connect(SyntheticToneConnector.source);
      session.stateChanges.listen((state) {
        if (state == trigger) unawaited(session.stop());
      });

      await session.start().then((_) {}, onError: (_) {});
      await pumpEventQueue();

      expect(session.state, SessionState.stopped);
      expect(!clockListened || clockCancelled, isTrue);
      unawaited(clock.close());
    });
  }

  test('a failed acquisition ends the session with start_failed', () async {
    final session = await connector(
      acquire: () async => throw StateError('device busy'),
    ).connect(SyntheticToneConnector.source);

    await expectLater(
      session.start(),
      throwsA(isA<VoiceError>().having((e) => e.code, 'code', 'start_failed')),
    );
    expect(session.state, SessionState.error);
  });
}
