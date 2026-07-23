# Changelog

Longview follows [Semantic Versioning](https://semver.org/) while its machine
protocol is versioned independently by `schemaVersion`.

## Unreleased

### Changed

- Longshot now uses a continuous ScreenCaptureKit stream, settled-frame gating,
  and capture-verified adaptive pacing instead of a fixed wait per frame.
- Scroll event cadence and AX value steps adapt from measured overlap while
  preserving a minimum 24% committed-frame overlap.
- Coarse-to-fine overlap matching and capture-time overlap reuse reduce repeated
  stitching work.
- Longshot receipts now report capture source, elapsed milliseconds, effective
  pixels per second, and the final calibrated pulse count.
- Event routes now use route-specific emission and stable-frame windows, while
  no-motion checks reuse the current stream frame instead of forcing a one-shot
  capture.
- Known no-op route hints avoid speculative background probes without weakening
  explicit `background-only` policy.
- Restoration verification now tolerates localized dynamic content and reports
  viewport, focus, and pointer outcomes independently.

## [0.3.0] - 2026-07-23

### Added

- MIT public project boundary with privacy, security, and contribution policies.
- `longview doctor` read-only readiness diagnostics.
- Transactional source install, immutable-tag update, managed uninstall, and
  machine-readable installation receipt.
- Arm64 and Intel GitHub CI contract.
- Private-by-default window title enumeration.

### Security

- PNG output now uses exclusive creation and owner-only `0600` permissions.
- Output symlinks are refused.
- Public verification enforces an allowlisted repository surface and rejects
  credentials, oversized artifacts, and captured media.

## [0.2.0] - 2026-07-23

- Initial agent-native longshot CLI with explicit WindowServer targeting,
  background-first route selection, overlap stitching, and state restoration.
