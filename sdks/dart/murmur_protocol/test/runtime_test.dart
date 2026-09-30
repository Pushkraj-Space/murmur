import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:murmur_protocol/murmur_protocol.dart';
import 'package:murmur_protocol/testing.dart';
import 'package:test/test.dart';

import '../example/fake_voice_connector.dart' as example;

void main() {
  group('typed wire models', () {
    test('constructs and serializes an audio format', () {
      final format = AudioFormat(
        sampleRateHz: 48000,
        channels: 2,
        encoding: AudioEncoding.pcmF32le,
        frameDurationMs: 0,
      );

      expect(format.toJson(), {
        'sampleRateHz': 48000,
        'channels': 2,
        'encoding': 'AUDIO_ENCODING_PCM_F32LE',
        'frameDurationMs': 0,
      });
      expect(
        AudioFormat(
          sampleRateHz: 16000,
          channels: 1,
          encoding: AudioEncoding.opus,
        ).toJson(),
        isNot(contains('frameDurationMs')),
      );
    });

    test('validates audio format construction and parsing', () {
      const uint32Max = 0xffffffff;
      expect(
        AudioFormat(
          sampleRateHz: uint32Max,
          channels: uint32Max,
          encoding: AudioEncoding.pcmS16le,
          frameDurationMs: uint32Max,
        ).toJson(),
        containsPair('frameDurationMs', uint32Max),
      );

      for (final constructor in <AudioFormat Function()>[
        () => AudioFormat(
          sampleRateHz: 0,
          channels: 1,
          encoding: AudioEncoding.pcmS16le,
        ),
        () => AudioFormat(
          sampleRateHz: uint32Max + 1,
          channels: 1,
          encoding: AudioEncoding.pcmS16le,
        ),
        () => AudioFormat(
          sampleRateHz: 16000,
          channels: 0,
          encoding: AudioEncoding.pcmS16le,
        ),
        () => AudioFormat(
          sampleRateHz: 16000,
          channels: uint32Max + 1,
          encoding: AudioEncoding.pcmS16le,
        ),
        () => AudioFormat(
          sampleRateHz: 16000,
          channels: 1,
          encoding: AudioEncoding.pcmS16le,
          frameDurationMs: -1,
        ),
        () => AudioFormat(
          sampleRateHz: 16000,
          channels: 1,
          encoding: AudioEncoding.pcmS16le,
          frameDurationMs: uint32Max + 1,
        ),
      ]) {
        expect(constructor, throwsFormatException);
      }

      expect(
        () => AudioFormat.fromJson({
          'sampleRateHz': 16000,
          'channels': 1,
          'encoding': 'AUDIO_ENCODING_UNSPECIFIED',
        }),
        throwsFormatException,
      );
    });

    test('constructs each typed session command', () {
      final source = _source();
      final format = _format();
      final controls = [
        SessionControl(
          protocol: ProtocolVersion.current,
          sessionId: 'session-1',
          requestSequence: BigInt.one,
          command: StartSession(
            source: source,
            mode: CaptureMode.holdToTalk,
            requestedFormat: format,
          ),
        ),
        SessionControl(
          protocol: ProtocolVersion.current,
          sessionId: 'session-1',
          requestSequence: BigInt.two,
          command: const StopSession(reason: 'done'),
        ),
        SessionControl(
          protocol: ProtocolVersion.current,
          sessionId: 'session-1',
          requestSequence: BigInt.from(3),
          command: const SetInputGate(open: false, flushAcceptedAudio: false),
        ),
        SessionControl(
          protocol: ProtocolVersion.current,
          sessionId: 'session-1',
          requestSequence: BigInt.from(4),
          command: const FinalizeSession(),
        ),
      ];

      expect(controls[0].toJson()['start'], {
        'source': source.toJson(),
        'mode': 'CAPTURE_MODE_HOLD_TO_TALK',
        'requestedFormat': format.toJson(),
      });
      expect(controls[1].toJson()['stop'], {'reason': 'done'});
      expect(controls[2].toJson()['inputGate'], {
        'open': false,
        'flushAcceptedAudio': false,
      });
      expect(controls[3].toJson()['finalize'], isEmpty);
    });

    test('preserves present default-valued command fields', () {
      for (final entry in <String, Map<String, Object?>>{
        'inputGate': {'open': false},
        'emptyInputGate': <String, Object?>{},
        'stop': <String, Object?>{},
        'start': <String, Object?>{},
      }.entries) {
        final field = entry.key == 'emptyInputGate' ? 'inputGate' : entry.key;
        final json = _controlJson(field, entry.value);
        expect(SessionControl.fromJson(json).toJson(), json);
      }

      final explicitUnspecified = _controlJson('start', {
        'mode': 'CAPTURE_MODE_UNSPECIFIED',
      });
      expect(
        SessionControl.fromJson(explicitUnspecified).toJson(),
        explicitUnspecified,
      );
    });

    test('rejects invalid typed command fields', () {
      for (final json in [
        _controlJson('inputGate', {'open': 0}),
        _controlJson('stop', {'reason': false}),
        _controlJson('start', {'mode': 'CAPTURE_MODE_UNKNOWN'}),
        _controlJson('start', {'requestedFormat': <String, Object?>{}}),
      ]) {
        expect(() => SessionControl.fromJson(json), throwsFormatException);
      }
    });

    test('keeps audio payload text verbatim with a typed format', () {
      final json = <String, Object?>{
        'protocol': {'major': 1, 'minor': 0},
        'sessionId': 'session-1',
        'sequence': '1',
        'monotonicTimeUs': '25',
        'format': {
          'sampleRateHz': 16000,
          'channels': 1,
          'encoding': 'AUDIO_ENCODING_PCM_S16LE',
        },
        'payload': '__8',
      };

      final frame = AudioFrame.fromJson(json);
      expect(frame.format, isA<AudioFormat>());
      expect(frame.payloadBase64, '__8');
      expect(frame.toJson(), json);
    });
  });

  group('fake voice connector', () {
    test('discovers configured sources in order', () async {
      expect(FakeVoiceConnector().sources.single.toJson(), {
        'sourceId': 'fake-source-1',
        'displayName': 'Synthetic microphone',
        'transport': 'SOURCE_TRANSPORT_SYNTHETIC',
        'capabilities': ['SOURCE_CAPABILITY_LIVE_AUDIO'],
      });

      final sources = [_source('a'), _source('b'), _source('c')];
      final connector = FakeVoiceConnector(sources: sources);
      expect(await connector.discoverSources().take(3).toList(), sources);

      for (final configured in [<VoiceSource>[], sources]) {
        final received = <VoiceSource>[];
        var done = false;
        final subscription = FakeVoiceConnector(
          sources: configured,
        ).discoverSources().listen(received.add, onDone: () => done = true);
        await pumpEventQueue();
        expect(received, configured);
        expect(done, isFalse, reason: 'discovery runs until cancelled');
        await subscription.cancel();
      }

      expect(
        () => FakeVoiceConnector(sources: [_source('a'), _source('a')]),
        throwsArgumentError,
      );
    });

    test('cancelling discovery stops later sources', () async {
      final sources = [_source('a'), _source('b'), _source('c')];
      final received = <VoiceSource>[];
      late final StreamSubscription<VoiceSource> subscription;
      subscription = FakeVoiceConnector(sources: sources)
          .discoverSources()
          .listen((source) {
            received.add(source);
            unawaited(subscription.cancel());
          });

      await pumpEventQueue();
      expect(received, [sources.first]);
    });

    test('connect failures are configurable and typed', () async {
      final failure = VoiceError(
        code: 'connect_failed',
        message: 'The synthetic source did not connect.',
        retryable: true,
      );
      final connector = FakeVoiceConnector(connectError: failure);
      final source = connector.sources.single;

      await expectLater(connector.connect(source), throwsA(same(failure)));
      await expectLater(connector.connect(source), throwsA(same(failure)));

      connector.connectError = null;
      final first = await connector.connect(source);
      expect(first.sessionId, 'fake-session-1');
      expect(first.source, same(source));

      final sameId = VoiceSource(
        id: source.id,
        displayName: 'Another name',
        transport: VoiceSourceTransport.network,
      );
      final second = await connector.connect(sameId);
      expect(second.sessionId, 'fake-session-2');
      expect(second.source, same(source));

      await expectLater(
        connector.connect(_source('missing')),
        throwsA(
          isA<VoiceError>()
              .having((error) => error.code, 'code', 'source_not_found')
              .having((error) => error.retryable, 'retryable', false),
        ),
      );
    });

    test('stop is terminal and keeps snapshots readable', () async {
      final session = await _connect();
      expect(session.state, SessionState.idle);
      expect(session.format, isNull);
      expect(session.error, isNull);

      final states = <SessionState>[];
      final stateSubscription = session.stateChanges.listen(states.add);
      final framesDone = session.frames.drain<void>();

      await session.start(
        requestedFormat: AudioFormat(
          sampleRateHz: 48000,
          channels: 2,
          encoding: AudioEncoding.pcmF32le,
        ),
      );
      expect(session.state, SessionState.listening);
      expect(session.format, same(syntheticAudioFormat));

      await session.stop(reason: 'test complete');
      await framesDone;
      await pumpEventQueue();

      expect(states, [
        SessionState.starting,
        SessionState.listening,
        SessionState.stopped,
      ]);
      expect(session.state, SessionState.stopped);
      expect(session.sessionId, 'fake-session-1');
      expect(session.source.id, 'fake-source-1');
      expect(session.format, same(syntheticAudioFormat));
      expect(session.error, isNull);
      expect(() => session.start(), throwsStateError);
      await stateSubscription.cancel();
    });

    test(
      'state changes have no replay and support subscribe-then-read',
      () async {
        final session = await _connect();
        await session.start();
        await pumpEventQueue();

        final states = <SessionState>[];
        final subscription = session.stateChanges.listen(states.add);
        expect(session.state, SessionState.listening);
        await pumpEventQueue();
        expect(states, isEmpty);

        await session.close();
        await pumpEventQueue();
        expect(states, [SessionState.stopped]);
        await subscription.cancel();
      },
    );

    test('completeStart requires a pending manual start', () async {
      final automatic = await _connect();
      expect(automatic.completeStart, throwsStateError);
      final pending = automatic.start();
      expect(automatic.completeStart, throwsStateError);
      await pending;

      final manual = await _connect(autoCompleteStart: false);
      expect(manual.completeStart, throwsStateError);
      final start = manual.start();
      await pumpEventQueue();
      expect(manual.state, SessionState.starting);
      manual.completeStart();
      await start;
      expect(manual.state, SessionState.listening);
      expect(manual.completeStart, throwsStateError);

      await manual.close();
      manual.completeStart();
      expect(manual.state, SessionState.stopped);
      await automatic.close();
    });

    for (final terminator in ['close', 'stop']) {
      test(
        '$terminator wins against a pending start without resurrection',
        () async {
          final session = await _connect(autoCompleteStart: false);
          final states = <SessionState>[];
          final stateSubscription = session.stateChanges.listen(states.add);
          final frames = <AudioFrame>[];
          final framesSubscription = session.frames.listen(frames.add);

          final cancelled = expectLater(
            session.start(),
            throwsA(
              isA<VoiceError>().having(
                (error) => error.code,
                'code',
                'cancelled',
              ),
            ),
          );
          await pumpEventQueue();
          expect(session.state, SessionState.starting);

          await (terminator == 'close'
              ? session.close()
              : session.stop(reason: 'cancel startup'));
          await cancelled;

          session.completeStart();
          await pumpEventQueue();

          expect(session.state, SessionState.stopped);
          expect(session.format, isNull);
          expect(frames, isEmpty);
          expect(states, [SessionState.starting, SessionState.stopped]);
          await stateSubscription.cancel();
          await framesSubscription.cancel();
        },
      );
    }

    test('stop wins against a scheduled automatic start', () async {
      final session = await _connect();
      final states = <SessionState>[];
      final stateSubscription = session.stateChanges.listen(states.add);
      final frames = session.frames.toList();

      final cancelled = expectLater(
        session.start(),
        throwsA(
          isA<VoiceError>().having((error) => error.code, 'code', 'cancelled'),
        ),
      );
      await session.stop();
      await cancelled;
      await pumpEventQueue();

      expect(states, [SessionState.starting, SessionState.stopped]);
      expect(session.state, SessionState.stopped);
      expect(session.format, isNull);
      expect(await frames, isEmpty);
      await stateSubscription.cancel();
    });

    test('failure during a pending start fails the start', () async {
      final session = await _connect(autoCompleteStart: false);
      final failure = VoiceError(
        code: 'start_failed',
        message: 'The synthetic source did not start.',
        retryable: false,
      );
      final failed = expectLater(session.start(), throwsA(same(failure)));

      await session.fail(failure);
      await failed;

      expect(session.state, SessionState.error);
      expect(session.error, same(failure));
      expect(session.format, isNull);
    });

    test('disconnect publishes its cause before the error state', () async {
      final session = await _connect();
      final disconnected = VoiceError(
        code: 'disconnected',
        message: 'The synthetic source disconnected.',
        retryable: true,
        metadata: {'transport': 'synthetic'},
      );
      final observedErrors = <VoiceError?>[];
      final stateSubscription = session.stateChanges.listen((state) {
        if (state == SessionState.error) observedErrors.add(session.error);
      });
      final frames = session.frames.toList();
      await session.start();

      await session.fail(disconnected);
      expect(await frames, hasLength(2));
      await pumpEventQueue();

      expect(observedErrors, [same(disconnected)]);
      await session.stop();
      await session.fail(
        VoiceError(code: 'late', message: 'Too late.', retryable: false),
      );
      expect(session.state, SessionState.error);
      expect(session.error, same(disconnected));
      expect(() => session.start(), throwsStateError);
      await stateSubscription.cancel();
    });

    test('repeated and concurrent terminators share one cleanup', () async {
      final session = await _connect();
      final states = <SessionState>[];
      final stateSubscription = session.stateChanges.listen(states.add);
      await session.start();

      final cleanups = [
        session.close(),
        session.stop(),
        session.close(),
        session.fail(
          VoiceError(code: 'late', message: 'Too late.', retryable: false),
        ),
      ];
      for (final cleanup in cleanups) {
        expect(cleanup, same(cleanups.first));
      }
      await Future.wait(cleanups);
      await session.close();
      await pumpEventQueue();

      expect(states, [
        SessionState.starting,
        SessionState.listening,
        SessionState.stopped,
      ]);
      expect(session.error, isNull);
      await stateSubscription.cancel();
    });

    test('listeners may terminate the session from callbacks', () async {
      final session = await _connect();
      final first = <SessionState>[];
      final second = <SessionState>[];
      Future<void>? stopped;
      final firstSubscription = session.stateChanges.listen((state) {
        first.add(state);
        if (state == SessionState.listening) stopped = session.stop();
      });
      final secondSubscription = session.stateChanges.listen(second.add);

      await session.start();
      await pumpEventQueue();
      await stopped;

      const expected = [
        SessionState.starting,
        SessionState.listening,
        SessionState.stopped,
      ];
      expect(first, expected);
      expect(second, expected);

      final other = await _connect();
      final received = <AudioFrame>[];
      final framesDone = Completer<void>();
      other.frames.listen((frame) {
        received.add(frame);
        unawaited(other.close());
      }, onDone: framesDone.complete);
      await other.start();
      await framesDone.future;
      expect(received, hasLength(2));
      expect(other.state, SessionState.stopped);

      await firstSubscription.cancel();
      await secondSubscription.cancel();
    });

    test('cleanup does not wait for never-listened streams', () async {
      final session = await _connect();
      await session.start();

      await session.close().timeout(const Duration(seconds: 1));

      expect(session.state, SessionState.stopped);
    });

    test('cleanup does not wait for paused stream consumers', () async {
      final session = await _connect();
      final frameSubscription = session.frames.listen((_) {});
      final stateSubscription = session.stateChanges.listen((_) {});
      frameSubscription.pause();
      stateSubscription.pause();
      await session.start();

      await session.close().timeout(const Duration(seconds: 1));

      expect(session.state, SessionState.stopped);
      await frameSubscription.cancel();
      await stateSubscription.cancel();
    });

    test('produces the canonical synthetic clip', () async {
      final fixture = File('../../../conformance/fixtures/audio-frames.jsonl')
          .readAsLinesSync()
          .where((line) => line.trim().isNotEmpty)
          .take(2)
          .map((line) => requireObject(jsonDecode(line), 'audio frame'))
          .toList();
      final session = await _connect();
      final clip = session.frames.take(2).toList();

      await session.start();
      final frames = await clip;

      for (var index = 0; index < 2; index++) {
        expect(frames[index].toJson(), {
          ...fixture[index],
          'sessionId': session.sessionId,
        });
        expect(base64Decode(frames[index].payloadBase64), hasLength(320));
      }
      await session.close();
    });

    test('connecting never captures and late consumers get the clip', () async {
      final idle = await _connect();
      final early = <AudioFrame>[];
      final earlySubscription = idle.frames.listen(early.add);
      await pumpEventQueue();
      expect(early, isEmpty);
      await idle.close();
      await earlySubscription.cancel();

      final session = await _connect();
      await session.start();
      await pumpEventQueue();
      final received = <AudioFrame>[];
      final subscription = session.frames.listen(received.add);
      await pumpEventQueue();

      expect(received.map((frame) => frame.sequence), [BigInt.one, BigInt.two]);
      expect(session.state, SessionState.listening);
      await session.close();
      await subscription.cancel();
    });

    test('example host code consumes the fake connector', () async {
      final clip = await example.captureSyntheticClip(FakeVoiceConnector());

      expect(clip.map((frame) => frame.sequence), [BigInt.one, BigInt.two]);
    });
  });
}

Future<FakeVoiceSession> _connect({bool autoCompleteStart = true}) {
  final connector = FakeVoiceConnector(autoCompleteStart: autoCompleteStart);
  return connector.connect(connector.sources.single);
}

AudioFormat _format() => AudioFormat(
  sampleRateHz: 16000,
  channels: 1,
  encoding: AudioEncoding.pcmS16le,
  frameDurationMs: 10,
);

VoiceSource _source([String id = 'source-1']) => VoiceSource(
  id: id,
  displayName: 'Synthetic microphone',
  transport: VoiceSourceTransport.synthetic,
  capabilities: {VoiceSourceCapability.liveAudio},
);

Map<String, Object?> _controlJson(
  String commandField,
  Map<String, Object?> body,
) => {
  'protocol': {'major': 1, 'minor': 0},
  'sessionId': 'session-1',
  'requestSequence': '1',
  commandField: body,
};
