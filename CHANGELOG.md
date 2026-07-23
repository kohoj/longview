# Changelog

Longview follows [Semantic Versioning](https://semver.org/) while its machine
protocol is versioned independently by `schemaVersion`.

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
