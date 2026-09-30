// A minimal, deterministic example connector for the connector authoring guide
// (docs/connector-authoring.md). It implements the SDK's `VoiceConnector` and
// `VoiceSession` for a synthetic sine-tone source, so it needs no permissions,
// hardware, or real audio.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:murmur_protocol/murmur_protocol.dart';

/// Discovers one synthetic tone source and connects idle sessions to it.
final class SyntheticToneConnector implements VoiceConnector {
  /// Creates a connector.
  ///
  /// [frameClock] ticks once per frame while a session is listening; tests pass
  /// a controllable stream instead of the default periodic timer. [acquire]
  /// simulates opening the device during `start` and may throw. [clockUs] is
  /// the host's monotonic clock in microseconds.
  SyntheticToneConnector({
    this.sampleRateHz = 16000,
    this.frameDurationMs = 20,
    this.frequencyHz = 440,
    Stream<void> Function(Duration frameDuration)? frameClock,
    Future<void> Function()? acquire,
    int Function()? clockUs,
  }) : _frameClock = frameClock ?? _periodicClock,
       _acquire = acquire ?? _noAcquisition,
       _clockUs = clockUs ?? _stopwatchClock;

  /// The only source this connector reports.
  static final VoiceSource source = VoiceSource(
    id: 'source-synthetic-tone',
    displayName: 'Synthetic tone',
    transport: VoiceSourceTransport.synthetic,
    capabilities: {VoiceSourceCapability.liveAudio},
    metadata: {'generator': 'sine'},
  );

  final int sampleRateHz;
  final int frameDurationMs;
  final double frequencyHz;
  final Stream<void> Function(Duration) _frameClock;
  final Future<void> Function() _acquire;
  final int Function() _clockUs;
  var _nextSession = 0;

  static Stream<void> _periodicClock(Duration frameDuration) =>
      Stream<void>.periodic(frameDuration);

  static Future<void> _noAcquisition() async {}

  static final Stopwatch _stopwatch = Stopwatch()..start();

  static int _stopwatchClock() => _stopwatch.elapsedMicroseconds;

  /// Emits the synthetic source and keeps scanning until cancelled.
  ///
  /// A hardware connector reports missing permissions as source state here
  /// instead of prompting, and stops its scan in `onCancel`.
  @override
  Stream<VoiceSource> discoverSources() {
    late final StreamController<VoiceSource> controller;
    controller = StreamController<VoiceSource>(
      onListen: () => controller.add(source),
    );
    return controller.stream;
  }

  @override
  Future<VoiceSession> connect(VoiceSource candidate) async {
    if (candidate.id != source.id) {
      throw VoiceError(
        code: 'connect_failed',
        message: 'Unknown source ${candidate.id}.',
        retryable: false,
      );
    }
    return SyntheticToneSession._(
      connector: this,
      sessionId: 'synthetic-tone-${++_nextSession}',
    );
  }
}

/// One capture connection to the synthetic source.
final class SyntheticToneSession implements VoiceSession {
  SyntheticToneSession._({
    required SyntheticToneConnector connector,
    required this.sessionId,
  }) : _connector = connector {
    _frames = StreamController<AudioFrame>(
      onListen: _flushFrames,
      onResume: _flushFrames,
      onCancel: _pending.clear,
    );
  }

  /// Undelivered frames kept while the consumer is absent or paused. When full,
  /// the oldest frame is dropped and counted in [droppedFrames].
  static const frameCapacity = 8;

  final SyntheticToneConnector _connector;
  final Queue<AudioFrame> _pending = Queue<AudioFrame>();
  // Asynchronous delivery: a listener may call stop() or close() when it sees
  // a transition without re-entering the transition that notified it.
  final StreamController<SessionState> _states =
      StreamController<SessionState>.broadcast();
  late final StreamController<AudioFrame> _frames;

  @override
  final String sessionId;

  SessionState _state = SessionState.idle;
  AudioFormat? _format;
  VoiceError? _error;
  Completer<void>? _pendingStart;
  StreamSubscription<void>? _clock;
  Future<void>? _cleanup;
  var _terminal = false;
  var _sequence = 0;
  var _samplesEmitted = 0;
  var _startedAtUs = 0;

  /// Frames dropped because the consumer did not keep up.
  var droppedFrames = 0;

  @override
  VoiceSource get source => SyntheticToneConnector.source;

  @override
  AudioFormat? get format => _format;

  @override
  SessionState get state => _state;

  @override
  Stream<SessionState> get stateChanges => _states.stream;

  @override
  VoiceError? get error => _error;

  @override
  Stream<AudioFrame> get frames => _frames.stream;

  @override
  Future<void> start({AudioFormat? requestedFormat}) {
    if (_terminal || _state != SessionState.idle) {
      throw StateError('capture can only start once, from an idle session');
    }
    final operation = Completer<void>();
    _pendingStart = operation;
    _transition(SessionState.starting);
    unawaited(_finishStart(operation, requestedFormat));
    return operation.future;
  }

  Future<void> _finishStart(
    Completer<void> operation,
    AudioFormat? requestedFormat,
  ) async {
    try {
      final negotiated = _negotiate(requestedFormat);
      await _connector._acquire();
      // A stop or close during startup wins: the start already failed with
      // `cancelled`, so release what this attempt acquired and do nothing else.
      if (_terminal) return;
      _format = negotiated;
      _startedAtUs = _connector._clockUs();
      _pendingStart = null;
      _transition(SessionState.listening);
      _clock = _connector
          ._frameClock(Duration(milliseconds: _connector.frameDurationMs))
          .listen((_) => _emitFrame());
      operation.complete();
    } on Object catch (cause) {
      if (_terminal) return;
      final failure = cause is VoiceError
          ? cause
          : VoiceError(
              code: 'start_failed',
              message: 'The synthetic source could not start.',
              retryable: true,
            );
      unawaited(_terminate(SessionState.error, failure));
    }
  }

  AudioFormat _negotiate(AudioFormat? requested) {
    final supported = AudioFormat(
      sampleRateHz: _connector.sampleRateHz,
      channels: 1,
      encoding: AudioEncoding.pcmS16le,
      frameDurationMs: _connector.frameDurationMs,
    );
    if (requested != null &&
        (requested.encoding != supported.encoding ||
            requested.channels != supported.channels ||
            requested.sampleRateHz != supported.sampleRateHz)) {
      // Refuse rather than silently producing a different format.
      throw VoiceError(
        code: 'format_unavailable',
        message:
            'Only mono PCM S16LE at ${supported.sampleRateHz} Hz is available.',
        retryable: false,
      );
    }
    return supported;
  }

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

  /// Simulates the source disappearing mid-session, for tests and the guide.
  Future<void> simulateDeviceLoss() => _terminate(
    SessionState.error,
    VoiceError(
      code: 'device_lost',
      message: 'The synthetic source disconnected.',
      retryable: true,
    ),
  );

  // Every termination path shares one cleanup; repeated and concurrent calls
  // await the same future.
  Future<void> _terminate(SessionState terminalState, VoiceError failure) {
    final existing = _cleanup;
    if (existing != null) return existing;
    _terminal = true;
    final pendingStart = _pendingStart;
    _pendingStart = null;
    if (pendingStart != null && !pendingStart.isCompleted) {
      pendingStart.completeError(failure);
    }
    if (terminalState == SessionState.error) _error = failure;
    _transition(terminalState);
    return _cleanup = _release();
  }

  Future<void> _release() async {
    final clock = _clock;
    _clock = null;
    await clock?.cancel();
    _pending.clear();
    // Closing must not wait for a consumer to drain the streams.
    unawaited(_frames.close());
    unawaited(_states.close());
  }

  void _emitFrame() {
    if (_terminal || _state != SessionState.listening) return;
    final samplesPerFrame =
        (_connector.sampleRateHz * _connector.frameDurationMs) ~/ 1000;
    final pcm = ByteData(samplesPerFrame * 2);
    for (var index = 0; index < samplesPerFrame; index++) {
      final t = (_samplesEmitted + index) / _connector.sampleRateHz;
      final sample =
          (math.sin(2 * math.pi * _connector.frequencyHz * t) * 0.25 * 32767)
              .round();
      pcm.setInt16(index * 2, sample, Endian.little);
    }
    // Timestamps come from the sample count, so transport jitter cannot make
    // audio appear to speed up or slow down.
    final monotonicTimeUs =
        _startedAtUs + (_samplesEmitted * 1000000) ~/ _connector.sampleRateHz;
    _samplesEmitted += samplesPerFrame;
    _pending.addLast(
      AudioFrame(
        protocol: ProtocolVersion.current,
        sessionId: sessionId,
        sequence: BigInt.from(++_sequence),
        monotonicTimeUs: BigInt.from(monotonicTimeUs),
        format: _format!,
        payloadBase64: base64Encode(pcm.buffer.asUint8List()),
      ),
    );
    if (_pending.length > frameCapacity) {
      _pending.removeFirst();
      droppedFrames++;
    }
    _flushFrames();
  }

  void _flushFrames() {
    while (_pending.isNotEmpty &&
        _frames.hasListener &&
        !_frames.isPaused &&
        !_frames.isClosed) {
      _frames.add(_pending.removeFirst());
    }
  }

  void _transition(SessionState next) {
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }
}
