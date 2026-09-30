# Connector authoring guide

A connector adapts one family of voice sources to Murmur: an Omi wearable, a
phone microphone, a headset, a network stream. This guide explains what a
connector must do, how it should behave at the edges, and how to show a reviewer
that it works.

Read [architecture.md](architecture.md) for where connectors sit, and
[voice-runtime.md](voice-runtime.md) for the capture coordinator that drives
them. The [connector checklist in CONTRIBUTING.md](../CONTRIBUTING.md#connector-pull-requests)
lists what a connector pull request must document; this guide explains the
expected behavior behind each item.

In Dart, a connector implements the SDK's `VoiceConnector` and `VoiceSession`
interfaces (`sdks/dart/murmur_protocol/lib/src/runtime.dart`). Other SDKs follow
the same model as they gain runtime interfaces. The worked example is
[`SyntheticToneConnector`](../sdks/dart/murmur_protocol/example/synthetic_tone_connector.dart),
a complete, tested implementation for a synthetic sine-wave source.

## What a connector owns

| Connector owns | Coordinator and host own |
| --- | --- |
| Discovering sources and reporting them as `VoiceSource` | Choosing a transcription or language provider |
| Reporting permission and readiness state | Input muting, warm unmute, and finalization |
| Connecting and opening one capture session | Endpointing and transcript assembly |
| Starting capture, producing `AudioFrame`s, stopping, and cleanup | Storing recordings, transcripts, or history |
| Parsing the source's codec and framing | Product UI, prompts, and settings |
| Declaring capabilities it actually implements | Retrying on behalf of the user |
| Actionable errors with stable codes | Interpreting what the user said |

## The manifest

Every connector ships a `connector.json` validated by
[`spec/connector-manifest.schema.json`](../spec/connector-manifest.schema.json).
`make check-conformance` checks every `connectors/**/connector.json`: required
and unknown fields, the ID and version grammar, the protocol major, duplicate
list entries, that the implementation path exists, and that at least one license
is named.

State the real status. `experimental` is the right starting point, and it is
welcome. `supported` means the documented platforms have passed the automated
tests and the physical validation below. Capabilities list what works today, not
what is planned.

## Lifecycle

```text
VoiceConnector                     VoiceSession
--------------                     ------------
discoverSources() ──▶ source
connect(source) ──────────────────▶ idle ── start() ──▶ starting ──▶ listening
                                                            │             │
                                     stop() / close() ◀─────┴─────────────┘
                                            │
                                            ▼
                                         stopped          (failure) ──▶ error
```

- **Discover.** `discoverSources()` is a single-subscription stream that scans
  until it is cancelled. Cancelling must stop the scan and release its
  resources. Do not prompt for permissions or open connections while scanning.
- **Connect.** `connect(source)` returns an **idle** session that is not
  capturing. On failure it throws a `VoiceError` (for example `connect_failed`)
  after releasing everything the attempt acquired; never return a half-connected
  session.
- **Start.** `start()` moves `idle → starting → listening`. `requestedFormat` is a
  preference; expose the negotiated result through `format`. Starting a session
  that is not idle throws `StateError`.
- **Stop and close.** Both end the session and share **one** cleanup operation:
  concurrent and repeated calls await the same future. Stopping is terminal; a new
  capture needs a newly connected session.
- **Failure.** A runtime failure sets `error` and then moves the session to
  `error`, which is also terminal.
- **Finalizing.** `SessionState.finalizing` is for a session that must finish
  audio it already accepted before it stops. Muting and utterance finalization
  are the coordinator's job ([voice-runtime.md](voice-runtime.md)), not the
  connector's.

`stateChanges` is a broadcast stream with no replay: consumers subscribe first
and then read `state`, tolerating one duplicate. Every getter stays readable after
the session ends.

## Capabilities

`VoiceSource.capabilities` tells the host what it may ask for. Declare a
capability only when it works end to end on the documented platforms:

- `liveAudio`: streaming capture during a session.
- `inputMute`: the source itself can mute its input without ending the session.
  The coordinator's software gate works without it.
- `storedAudio`, `battery`, `hardwareControl`, `outputAudio`,
  `backgroundCapture`, `speakerVerification`: only with documented behavior and
  tests.

When the host asks for something undeclared, fail with a stable code instead of
silently ignoring the request.

## Discovery and permissions

- Report missing permissions (microphone, Bluetooth, local network) as state the
  host can act on. The host, not the connector, decides when to prompt.
- Keep `VoiceSource.metadata` non-sensitive. Raw device identifiers such as MAC
  addresses or serial numbers, credentials, signed URLs, and user speech are
  forbidden. Use a stable, locally derived source ID instead of a hardware
  address.
- A source that disappears during discovery simply stops being reported. A source
  that disappears during a session is an interruption (below).

## Audio format and framing

- Every `AudioFrame.format` states `sampleRateHz`, `channels`, `encoding`, and
  `frameDurationMs`. Keep the format constant within a session.
- If the host requests a format the source cannot produce, fail `start` with a
  code such as `format_unavailable`. Do not silently deliver something else.
  Resampling belongs in a clearly documented processing step, not hidden inside
  the transport.
- For PCM, the payload length must match the format:
  `sampleRateHz × channels × bytesPerSample × frameDurationMs / 1000`. The
  conformance fixtures check this.
- Decode source codecs (for example Opus, LC3, or a vendor framing) inside the
  connector, and cite the protocol source you followed (see provenance below).

## Timestamps and ordering

- `monotonicTimeUs` comes from the producing host's monotonic clock. It is only
  comparable within one session on one machine. Never use wall-clock time.
- Derive audio frame timestamps from the sample count since capture started, not
  from when a packet arrived. Transport jitter then cannot make audio appear to
  speed up or slow down. The example computes
  `start + samplesEmitted × 1e6 / sampleRate`.
- Frame `sequence` starts at 1 in each session and strictly increases. Ordering
  uses `sequence`, never timestamps.

## Backpressure

`frames` is a single-subscription stream. A connector must not buffer audio
without limit when the consumer is absent, paused, or slow.

- Bound every pending frame, including events queued inside your stream
  controller.
- Document which frames are dropped when the buffer is full. Dropping the oldest
  keeps the stream current; count the drops so they can be reported. The example
  keeps at most eight frames and exposes `droppedFrames`.
- Never block the transport's callback thread on a slow consumer, and never let
  stream drainage delay cleanup.

## Interruption, cancellation, and cleanup

- **Cancellation during startup.** If `stop` or `close` wins against a pending
  `start`, the start completes with a `VoiceError` whose code is `cancelled`, and
  anything acquired late is released. The session must not reach `listening` or
  emit frames afterwards.
- **Source loss mid-session.** Set `error` with a code such as `device_lost` and
  an honest `retryable`, move to `error`, and release resources. Do not reconnect
  in a tight loop; reconnection is host-driven or bounded with backoff, and
  documented.
- **After termination, nothing more.** No frames or state changes for an ended
  session, including late packets still in flight from the transport. The frame
  stream completes.
- **Release everything:** sockets, BLE subscriptions, audio sessions, timers, and
  file handles. A leaked subscription after `close` is a bug.

## Errors

Throw or record `VoiceError`: a stable, machine-readable `code` in `snake_case`,
a `message` that is safe to show but is not stable API, and `retryable`. Reuse
existing codes where they fit:

| Code | When |
| --- | --- |
| `connect_failed` | `connect` could not open the source |
| `start_failed` | `start` could not acquire capture resources |
| `format_unavailable` | the requested format cannot be produced |
| `cancelled` | `stop` or `close` won against a pending `start` |
| `device_lost` | the source disappeared during a session |

Messages must not contain speech, credentials, audio, or raw device identifiers.
Document every code your connector can produce.

## Testing

### Automated tests (required)

Build a fake or fixture for the transport so every test runs without hardware,
as the example does with an injectable frame clock and startup step. Cover at
least:

- discovery reports a valid `VoiceSource` and stops when cancelled;
- `connect` returns an idle session, and fails with a stable code for a bad source;
- `start` moves `starting → listening` and negotiates the format;
- frames have the right format, payload length, sample-derived timestamps, and
  increasing sequences, and are deterministic for the same input;
- a refused format fails `start` and ends in `error`;
- cancellation during startup (`cancelled`, never `listening`);
- source loss mid-session (`device_lost`, frame stream completes);
- the frame buffer is bounded and drops as documented;
- `stop` and `close` share one cleanup and are terminal;
- every emitted `AudioFrame` round-trips through the SDK's JSON model. This is
  the cheapest proof that you emit valid `murmur.v1`.

Use synthetic audio (tones, silence, generated noise). Never commit recordings,
transcripts, or real device identifiers.

### Conformance

- `make check-conformance` validates the shared fixtures and every connector
  manifest.
- Run your SDK's surface (`make check-dart`, `check-typescript`, and so on).
- If your connector exposes new observable protocol behavior, add fixtures under
  `conformance/fixtures` and register them in `conformance/manifest.json`.

### Physical validation (required before `supported`)

Record, for each platform and device model you claim:

1. device model, firmware, OS and version, host app build;
2. discover, connect, start, 60 seconds of capture, stop, and a second connect and
   capture;
3. source removed or powered off mid-session: the observed error and cleanup;
4. app backgrounded and restored, if background capture is claimed;
5. audio sanity: format, frame cadence, and absence of gaps, checked on a
   synthetic or consented test signal;
6. anything that failed or was not tested.

Put the results in the pull request. Untested platforms stay out of `platforms`.

## Provenance and license checklist

Before opening a pull request, confirm:

- [ ] Every protocol detail (service UUIDs, packet layouts, codecs) cites its
      source: official documentation, an open-source implementation, or your
      own observation of hardware you own.
- [ ] Adapted code keeps its copyright and license notice, and the license is
      compatible with Apache-2.0. Record it under `licenses` in
      `connector.json` (for example `"protocolReference": "MIT"`) and in
      `THIRD_PARTY_NOTICES.md` if code was adapted.
- [ ] No code or constants come from proprietary SDKs, decompiled apps, or
      sources whose terms forbid reuse.
- [ ] Bundled codec or model weights have a license that permits redistribution.
- [ ] No credentials, device identifiers, recordings, or private endpoints are
      committed, including in tests and fixtures.

## Proposing a connector

Open a [connector proposal](../.github/ISSUE_TEMPLATE/connector-proposal.yml)
before writing a new connector family. It asks for the source and platforms,
implementation language, protocol sources, hardware access, and privacy
implications, so the direction can be agreed on before the work starts.

## The example connector

- [`sdks/dart/murmur_protocol/example/synthetic_tone_connector.dart`](../sdks/dart/murmur_protocol/example/synthetic_tone_connector.dart)
  implements `VoiceConnector` and `VoiceSession` for a synthetic sine tone:
  - an idle session from `connect`;
  - a cancellable start with an injectable startup step;
  - PCM S16LE frames with sample-derived timestamps and an eight-frame drop-oldest
    buffer;
  - one shared cleanup for `stop` and `close`;
  - `simulateDeviceLoss()` for the interruption path.
- [`sdks/dart/murmur_protocol/test/synthetic_tone_connector_test.dart`](../sdks/dart/murmur_protocol/test/synthetic_tone_connector_test.dart)
  covers the whole required test list above and runs with `make check-dart`.
- [`connectors/examples/synthetic-tone/connector.json`](../connectors/examples/synthetic-tone/connector.json)
  is its `experimental` manifest, checked by `make check-conformance`.
