import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../protocol.dart';
import '../runtime.dart';
import '../session.dart';
import '../source.dart';

/// The fixed format negotiated by every [FakeVoiceSession].
///
/// 16,000 Hz, mono, little-endian signed 16-bit PCM in 10 ms frames: 160
/// samples and 320 bytes per frame.
final AudioFormat syntheticAudioFormat = AudioFormat(
  sampleRateHz: 16000,
  channels: 1,
  encoding: AudioEncoding.pcmS16le,
  frameDurationMs: 10,
);

const _samplesPerFrame = 160;
const _frameDurationUs = 10000;

/// A 1 kHz sine: sample `n` is `round(8000 * sin(2 * pi * 1000 * n / 16000))`.
final String _sinePayload = () {
  final samples = ByteData(_samplesPerFrame * 2);
  for (var n = 0; n < _samplesPerFrame; n++) {
    final value = (8000 * math.sin(2 * math.pi * 1000 * n / 16000)).round();
    samples.setInt16(n * 2, value, Endian.little);
  }
  return base64Encode(samples.buffer.asUint8List());
}();

final String _silencePayload = base64Encode(Uint8List(_samplesPerFrame * 2));

/// A deterministic, hardware-free [VoiceConnector] for tests and examples.
///
/// Discovery emits the configured [sources] in order, one per microtask, and
/// stays open until the subscription is cancelled. [connect] accepts only a
/// configured source id and returns an idle [FakeVoiceSession] with the id
/// `fake-session-1`, `fake-session-2`, and so on.
///
/// The fake uses no timers, clocks, randomness, files, or microphones.
final class FakeVoiceConnector implements VoiceConnector {
  /// Creates a fake connector for [sources].
  ///
  /// [sources] defaults to one synthetic microphone and may be empty. Source
  /// ids must be unique. When [autoCompleteStart] is `false`,
  /// [FakeVoiceSession.start] stays in [SessionState.starting] until
  /// [FakeVoiceSession.completeStart] is called.
  FakeVoiceConnector({
    Iterable<VoiceSource>? sources,
    this.autoCompleteStart = true,
    this.connectError,
  }) : sources = List.unmodifiable(
         sources ??
             [
               VoiceSource(
                 id: 'fake-source-1',
                 displayName: 'Synthetic microphone',
                 transport: VoiceSourceTransport.synthetic,
                 capabilities: {VoiceSourceCapability.liveAudio},
               ),
             ],
       ) {
    final ids = <String>{};
    for (final source in this.sources) {
      if (!ids.add(source.id)) {
        throw ArgumentError.value(source.id, 'sources', 'duplicate source id');
      }
    }
  }

  /// The discoverable sources, in discovery order.
  final List<VoiceSource> sources;

  /// Whether sessions reach [SessionState.listening] on their own after
  /// [FakeVoiceSession.start].
  final bool autoCompleteStart;

  /// The error every [connect] call throws while this is non-null.
  ///
  /// Set it back to `null` to let the next [connect] succeed.
  VoiceError? connectError;

  var _sessionCount = 0;

  @override
  Stream<VoiceSource> discoverSources() {
    late final StreamController<VoiceSource> controller;
    var next = 0;
    void emitNext() {
      if (!controller.hasListener || next >= sources.length) return;
      controller.add(sources[next++]);
      scheduleMicrotask(emitNext);
    }

    // Each add runs in its own microtask, never inside a consumer callback,
    // so synchronous delivery lets a cancel stop every later source.
    controller = StreamController<VoiceSource>(
      sync: true,
      onListen: () => scheduleMicrotask(emitNext),
    );
    return controller.stream;
  }

  @override
  Future<FakeVoiceSession> connect(VoiceSource source) async {
    final failure = connectError;
    if (failure != null) throw failure;
    for (final configured in sources) {
      if (configured.id == source.id) {
        return FakeVoiceSession._(
          source: configured,
          sessionId: 'fake-session-${++_sessionCount}',
          autoCompleteStart: autoCompleteStart,
        );
      }
    }
    throw VoiceError(
      code: 'source_not_found',
      message: 'The fake connector has no source with this id.',
      retryable: false,
      metadata: {'sourceId': source.id},
    );
  }
}

/// A deterministic [VoiceSession] created by [FakeVoiceConnector].
///
/// States follow `idle → starting → listening → stopped | error`; the fake
/// never produces [SessionState.finalizing]. On entering listening the session
/// produces exactly two frames in [syntheticAudioFormat], matching the
/// canonical `conformance/fixtures/audio-frames.jsonl` clip:
///
/// 1. sequence 1, `monotonicTimeUs` 10000: a 1 kHz sine with sample `n` equal
///    to `round(8000 * sin(2 * pi * 1000 * n / 16000))`;
/// 2. sequence 2, `monotonicTimeUs` 20000: 320 zero bytes.
///
/// Timestamps use a synthetic clock that is 0 when capture starts, and each
/// frame is stamped with the end of the 10 ms it covers. The session then
/// stays listening and silent until it terminates. All audio is generated from
/// the formula above; none of it is recorded.
///
/// [frames] buffers at most these two frames for an absent or paused consumer
/// and never drops one. Both streams deliver asynchronously, so a listener may
/// call [stop], [close], or [fail] from its callback.
final class FakeVoiceSession implements VoiceSession {
  FakeVoiceSession._({
    required this.source,
    required this.sessionId,
    required bool autoCompleteStart,
  }) : _autoCompleteStart = autoCompleteStart;

  @override
  final VoiceSource source;

  @override
  final String sessionId;

  final bool _autoCompleteStart;
  final StreamController<SessionState> _stateController =
      StreamController<SessionState>.broadcast();
  final StreamController<AudioFrame> _frameController =
      StreamController<AudioFrame>();

  SessionState _state = SessionState.idle;
  AudioFormat? _format;
  VoiceError? _error;
  Completer<void>? _pendingStart;
  Future<void>? _cleanup;

  @override
  AudioFormat? get format => _format;

  @override
  SessionState get state => _state;

  @override
  Stream<SessionState> get stateChanges => _stateController.stream;

  @override
  VoiceError? get error => _error;

  @override
  Stream<AudioFrame> get frames => _frameController.stream;

  /// Starts capture. [requestedFormat] is ignored; the fake always negotiates
  /// [syntheticAudioFormat].
  @override
  Future<void> start({AudioFormat? requestedFormat}) {
    if (_cleanup != null || _state != SessionState.idle) {
      throw StateError('capture can only start from an idle session');
    }
    final operation = Completer<void>();
    _pendingStart = operation;
    _transition(SessionState.starting);
    if (_autoCompleteStart) {
      scheduleMicrotask(() {
        if (identical(_pendingStart, operation)) _finishStart();
      });
    }
    return operation.future;
  }

  /// Completes a start held by `autoCompleteStart: false`.
  ///
  /// This is a no-op after the session terminates. It throws [StateError] when
  /// no manually completed start is pending.
  void completeStart() {
    if (_cleanup != null) return;
    if (_autoCompleteStart || _pendingStart == null) {
      throw StateError('no manually completed start is pending');
    }
    _finishStart();
  }

  void _finishStart() {
    final operation = _pendingStart!;
    _pendingStart = null;
    _format = syntheticAudioFormat;
    _transition(SessionState.listening);
    _frameController
      ..add(_frame(1, _sinePayload))
      ..add(_frame(2, _silencePayload));
    operation.complete();
  }

  AudioFrame _frame(int sequence, String payload) => AudioFrame(
    protocol: ProtocolVersion.current,
    sessionId: sessionId,
    sequence: BigInt.from(sequence),
    monotonicTimeUs: BigInt.from(sequence * _frameDurationUs),
    format: syntheticAudioFormat,
    payloadBase64: payload,
  );

  @override
  Future<void> stop({String? reason}) => _terminate(
    SessionState.stopped,
    VoiceError(
      code: 'cancelled',
      message: 'Session start was cancelled.',
      retryable: true,
    ),
  );

  @override
  Future<void> close() => stop();

  /// Ends the session with [failure], as a device loss or remote disconnect.
  ///
  /// A pending start completes with [failure]. This shares the cleanup of
  /// [stop] and [close]; after the session terminates it changes nothing.
  Future<void> fail(VoiceError failure) =>
      _terminate(SessionState.error, failure);

  Future<void> _terminate(SessionState terminalState, VoiceError failure) {
    final existing = _cleanup;
    if (existing != null) return existing;
    final cleanup = _cleanup = Future<void>.value();

    final pendingStart = _pendingStart;
    _pendingStart = null;
    pendingStart?.completeError(failure);
    if (terminalState == SessionState.error) _error = failure;
    _transition(terminalState);

    // Closing may wait on absent or paused consumers; cleanup never does.
    unawaited(_frameController.close());
    unawaited(_stateController.close());
    return cleanup;
  }

  void _transition(SessionState next) {
    _state = next;
    _stateController.add(next);
  }
}
