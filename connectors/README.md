# Murmur connectors

A connector adapts a voice source to the Murmur protocol. Connectors may be
implemented in any language and may run in-process, behind FFI, or as a local or
remote service. Their public behavior is defined by `murmur.v1`, not by a UI
framework.

Each connector should publish a `connector.json` manifest containing:

- connector and implementation versions
- compatible Murmur protocol major version
- source transports and capabilities
- implementation language and SDK
- supported platforms
- code and protocol provenance licenses
- implementation and documentation locations

The initial Omi connector remains inside the Flutter reference app while its
audio path is being completed. Its manifest makes that limitation explicit and
allows a native, Rust, TypeScript, or other implementation to be added later
without changing host applications.

[`examples/synthetic-tone`](examples/synthetic-tone) is the manifest for a
minimal, tested Dart connector for a synthetic source
([implementation](../sdks/dart/murmur_protocol/example/synthetic_tone_connector.dart)).
It shows the expected lifecycle, framing, timestamps, backpressure, cleanup, and
error behavior without hardware.

See the [connector authoring guide](../docs/connector-authoring.md) for how to
build and validate a connector, and [CONTRIBUTING.md](../CONTRIBUTING.md) for the
connector acceptance rules.
