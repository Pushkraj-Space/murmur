# Voice wearable survey: choosing the next connector

Survey for [#13](https://github.com/october-dev/murmur/issues/13), checked on **2026-09-25**. It compares voice
wearables and open hardware as candidates for Murmur's next connector after Omi, and recommends one.

This is desk research from vendor pages, official SDK and protocol documentation, and repositories and their
`LICENSE` files. No hardware was bought or tested, and no closed protocol was examined. Availability changes quickly:
Limitless stopped selling its Pendant to new customers after its acquisition, and Brilliant Labs replaced Frame with
Halo in its official store. Re-check any row before starting implementation. Repository activity below is as of the
survey date.

**Evidence labels**

- **D**: documented in a primary source (vendor site, official docs, SDK repository, package registry, or `LICENSE`
  file), linked in the row or the notes.
- **R**: reported by secondary sources (for example news coverage of an acquisition), not confirmed on a vendor page.
- **U**: not confirmed from a primary source during this survey. Treat it as an open question, not as a limitation or a
  capability.
- **Inference**: a conclusion drawn from documented facts, stated as such.

## Summary

| Candidate | Buy new today | Transport | Third-party live audio | SDK / code license | Vendor account or cloud needed | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| Omi (baseline) | Yes (D) | BLE (D) | Yes: BLE audio service; Opus 16 kHz default, PCM and µ-law 8/16 kHz (D) | MIT (D) | U | Current connector |
| **Mentra Live** | Yes, US retail only (D) | BLE and Wi-Fi (D) | Yes: Mentra Bluetooth SDK `mic_pcm` (16 kHz, 16-bit, mono) and `mic_lc3` events (D) | Apache-2.0 SDK source and Android/iOS packages; npm package metadata says MIT (D) | No: works offline without Mentra-hosted cloud (D) | **Recommended** |
| Brilliant Labs Halo | Yes, shipments began early August (D) | BLE (D) | U: LE-Audio-style voice pipeline mentioned, no third-party stream documented | SDK BSD-3-Clause (D); firmware mixed, incl. restrictive Alif SDK license (D) | No: pairing and self-flashed OTA firmware (D) | Runner-up |
| Even Realities G1/G2 | G2 yes; G1 U | BLE (D) | G2 microphone events through the Mentra Bluetooth SDK (D); G1 U | Official Even Hub SDK license U | U | Reach G2 through the Mentra SDK |
| Plaud NotePin | Yes (D) | BLE (D) | PCM via `blePcmData` during recording and sync (D); general-purpose live capture U | Sample app Apache-2.0, **SDK binaries proprietary** (D) | Yes: per-user JWT from the vendor (D) | Not recommended |
| Limitless Pendant | No: sales to new customers stopped after acquisition (R) | Cloud export (D) | No live stream; post-hoc Ogg Opus export via REST (D) | No public SDK or code license found (U) | Yes: API key (D) | Excluded |
| Bee | Yes, $49.99 from Amazon (D) | U | No raw audio; processed data only (D) | U | Yes: vendor login (D) | Excluded |
| OpenGlass | N/A: superseded (D) | BLE (D) | Superseded | MIT (D) | No | Merged into Omi (D) |
| DIY XIAO ESP32-S3 pendant | No product; open designs only (D) | BLE (Owl) / Wi-Fi (xiaozhi) (D) | Yes, the builder controls the firmware (D) | MIT (D) | No | No maintained wearable design |

## Candidates

### Omi (baseline)

- **Audio (D):** BLE service `19B10000-E8F2-537E-4F6C-D104768A1214` with an audio data characteristic and a codec-type
  characteristic. Supported: PCM 16/8 kHz, µ-law 16/8 kHz, and Opus 16 kHz, all mono. Opus has been the default since
  firmware v1.0.3. [Protocol docs](https://docs.omi.me/doc/developer/Protocol)
- **License (D):** MIT. [BasedHardware/omi](https://github.com/BasedHardware/omi), not archived.
- **Availability (D):** Omi and DevKit models sold on [omi.me](https://www.omi.me/).
- **Offline / BYOK:** U from primary docs. Inference: because the BLE protocol is documented, local capture does not
  depend on the vendor cloud; this is how Murmur's connector works.

### Mentra Live (recommended)

- **Availability (D):** sold on the [vendor site](https://mentraglass.com/pages/live). "Retail website orders ship only
  to addresses within the United States"; business orders outside the US go through Mentra support.
- **Transport (D):** BLE and Wi-Fi.
- **Integration path (D):** Mentra offers two SDKs.
  - The Miniapp SDK (`session.mic.onAudioChunk()`) is beta. Its miniapps run on the phone inside the Mentra App, and
    "there is currently no way to distribute a miniapp built with the Miniapp SDK".
  - For Mentra Live, Mentra writes: "we recommend using the Mentra Bluetooth SDK", which connects an Android or iOS app
    directly to the glasses. [Overview](https://docs.mentraglass.com/app-devs/getting-started/overview)
  - A Murmur connector cannot live inside the Mentra App, so the **Bluetooth SDK** is the path.
- **Audio (D):** with capture enabled, the Bluetooth SDK emits continuous `mic_pcm` events (`sampleRate` 16000,
  `bitsPerSample` 16, `channels` 1) and, when enabled, `mic_lc3` events with frame duration, frame size, and bitrate.
  [Audio guide](https://github.com/Mentra-Community/Mentra-Bluetooth-SDK-Starter-Kit/blob/main/docs/audio-guide.md),
  [API reference](https://github.com/Mentra-Community/Mentra-Bluetooth-SDK-Starter-Kit/blob/main/docs/api-reference.md).
  The BLE wire protocol is described in
  [mentra-live-ble-wire-protocol.md](https://github.com/Mentra-Community/Mentra-Bluetooth-SDK-Starter-Kit/blob/main/docs/mentra-live-ble-wire-protocol.md).
- **Account and cloud (D):** "Your software can control the camera, speakers, microphones, touchpad, and buttons, work
  offline, and integrate without depending on Mentra-hosted cloud infrastructure."
  ([Mentra Live](https://mentraglass.com/pages/live))
- **Platforms (D):** Android (`com.mentraglass:bluetooth-sdk` on Maven Central), iOS 15.1+ (Swift package
  [mentra-bluetooth-sdk-ios](https://github.com/Mentra-Community/mentra-bluetooth-sdk-ios)), and React Native / Expo
  (`@mentra/bluetooth-sdk` on npm).
  [Getting started](https://github.com/Mentra-Community/Mentra-Bluetooth-SDK-Starter-Kit/blob/main/docs/getting-started.md)
- **License of the published SDK (D):**
  - The SDK source is [`mobile/modules/bluetooth-sdk`](https://github.com/Mentra-Community/MentraOS/tree/dev/mobile/modules/bluetooth-sdk)
    in MentraOS, whose `LICENSE` is Apache-2.0.
  - The Maven Central POM for `com.mentraglass:bluetooth-sdk` declares Apache-2.0, and the iOS package repository is
    Apache-2.0.
  - The npm metadata for `@mentra/bluetooth-sdk` declares **MIT**, which disagrees with the source `LICENSE`. Both are
    permissive and compatible with Apache-2.0, but the mismatch should be raised with Mentra.
  - The Android module also bundles `lc3Lib` and `silero` components, whose licenses are U.
- **Devices with microphones (D):** the SDK's
  [hardware table](https://github.com/Mentra-Community/Mentra-Bluetooth-SDK-Starter-Kit/blob/main/docs/hardware-integration.md)
  lists microphones on Mentra Live and G2 only. Other glasses supported by the Mentra App (G1, Vuzix Z100) are not
  listed for the Bluetooth SDK, so their audio through it is U.
- **Offline / BYOK:** offline operation is documented (above). Inference: because PCM reaches the app, BYOK or
  on-device transcription is possible; Mentra also publishes an offline assistant example,
  [Edge_AI_SmartGlasses](https://github.com/Mentra-Community/Edge_AI_SmartGlasses) (D).
- **Background limits:** U.

### Brilliant Labs Halo (runner-up)

- **Availability (D):** Halo is sold on [brilliant.xyz](https://brilliant.xyz/products/halo) at $399; the page says
  "shipments beginning in early August". The earlier Frame is no longer offered in the official store.
- **Firmware (D):** [halo-firmware](https://github.com/brilliantlabsAR/halo-firmware) supports self-built firmware over
  OTA with "no cable, no dev kit, no vendor tooling". Its README states the repository "is therefore *not* uniformly
  Apache-2.0": Brilliant code is Apache-2.0 per file, but the vendored Alif Semiconductor SDK license "restricts use to
  Alif silicon and forbids relicensing under copyleft terms". GitHub reports the license as `NOASSERTION`.
- **SDK (D):** [brilliant_sdk](https://github.com/brilliantlabsAR/brilliant_sdk), BSD-3-Clause, Flutter, Python and
  Web Bluetooth.
- **Audio:** the README mentions "LE-Audio-style voice pipelines with on-device echo cancellation" (D), but documents no
  third-party microphone stream (U).

### Even Realities G1 / G2

- The vendor's [G1 page](https://www.evenrealities.com/g1) currently leads to G2. G1 new-sale availability is U.
- G2 microphone events are available through the Mentra Bluetooth SDK (D, hardware table above).
- An Even Hub SDK for G2 is referenced publicly. Its microphone access and license terms are U; its documentation page
  did not load during this survey.
- Community BLE protocol notes for G1 exist, for example in [AGiXT/mobile](https://github.com/AGiXT/mobile). They are
  reverse-engineered, not vendor documentation, and are out of scope under this issue's rules.

### Plaud NotePin

- **Availability (D):** sold on [plaud.ai](https://www.plaud.ai/products/plaud-notepin).
- **SDK (D):** [plaud-sdk-public](https://github.com/Plaud-AI/plaud-sdk-public), iOS 14+ and Android 5.0+. The README
  advertises "Real-time recording with live PCM waveform", and `blePcmData` "delivers decoded PCM (640 bytes, 16kHz
  mono)". Whether PCM is available for general-purpose live capture outside Plaud's recording and sync flow is U.
- **License (D):** the template app is Apache-2.0, but "the Plaud SDK binaries in the `sdk/` directory (iOS frameworks
  and Android AAR) are proprietary and distributed under a separate license." A connector would depend on
  closed binaries.
- **Authentication (D):** a per-user JWT obtained through the vendor's partner API, plus separate developer-portal keys
  for vendor transcription.

### Limitless Pendant (excluded)

- Meta's acquisition of Limitless and the end of Pendant sales to new customers were
  [reported on 2025-12-05](https://techcrunch.com/2025/12/05/meta-acquires-ai-device-startup-limitless/) (R). The
  vendor's developer page does not mention it.
- The developer API is a cloud REST API with an `X-API-Key` header. Audio is exported after the fact as Ogg Opus, in
  windows of up to two hours (D). [Developers](https://www.limitless.ai/developers)
- No public SDK or code license was found (U).
- Excluded: no longer sold new (R), and no live audio (D).

### Bee (excluded)

- The [vendor site](https://www.bee.computer/) sells Bee at $49.99 and carries Amazon branding (D).
- The developer [proxy and CLI](https://docs.bee.computer/docs/proxy) expose processed data (facts, to-dos,
  conversations, summaries) behind a vendor login (D). No raw or live audio is documented.
- Excluded: no raw audio.

### OpenGlass (superseded)

- The [repository](https://github.com/BasedHardware/OpenGlass) states it moved into the Omi repository and is no longer
  supported (D). MIT. The last push was 2025-09-22.

### DIY XIAO ESP32-S3 Sense pendant

- [OwlAIProject/Owl](https://github.com/OwlAIProject/Owl) (MIT) documents a XIAO ESP32-S3 Sense wearable over BLE (D),
  but its last push was 2024-03-17.
- [78/xiaozhi-esp32](https://github.com/78/xiaozhi-esp32) (MIT, with pushes in September 2026) is a maintained ESP32
  voice assistant. It is Wi-Fi or cellular first and not a wearable reference design (D).
- No maintained, BLE-first open pendant design was found. A DIY source is better served by Murmur's generic network or
  local-audio connectors than by a device-specific one.

## Recommendation: Mentra Live through the Mentra Bluetooth SDK

Build the next connector for **Mentra Live** on the **Mentra Bluetooth SDK**, consuming its `mic_pcm` events (and
optionally `mic_lc3`).

**Why**

- It is the only candidate besides Omi with a documented third-party microphone stream and a documented format.
- It connects the app directly to the glasses and works offline without Mentra-hosted cloud, which matches Murmur's
  local-first design.
- Its SDK source and Android and iOS packages are Apache-2.0, the same license as Murmur. Halo's firmware (Alif SDK
  terms) and Plaud's proprietary SDK binaries both fail this test.
- The hardware is on sale today from an independent vendor.
- The same SDK also exposes G2 microphones, so a second device may follow with little extra work.

**Tradeoffs and risks**

- **License details.** Confirm the licenses of the bundled `lc3Lib` and `silero` components, and ask Mentra to reconcile
  the npm `MIT` metadata with the Apache-2.0 `LICENSE`.
- **Codec.** PCM is 16 kHz, 16-bit mono. LC3 needs a decoder, so start with PCM and report the format through
  `AudioFrame.format`.
- **Glasses, not a pendant.** Capture posture, battery life and background behavior differ from Omi. Background limits
  are U and need physical validation before the connector is marked supported.
- **Availability.** Retail sales are US-only.
- **Moving target.** Re-check availability and SDK APIs at implementation time.

**Runner-up: Brilliant Labs Halo.** It is the most open hardware here: user-built firmware over OTA, BSD-3-Clause SDKs,
and no vendor tooling. It becomes the better choice if Brilliant documents third-party microphone streaming and the
Alif SDK terms are confirmed compatible with what Murmur would adapt. That is worth a follow-up question to the vendor.

## Out of scope

No hardware was purchased, no connector was implemented, and no closed protocol was reverse engineered. Community
reverse-engineering notes are listed only to show they exist, not as sources.
