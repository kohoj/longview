# Contributing to Longview

Longview favors small, explicit modules and a narrow trust boundary. A change is
complete only when its behavior, JSON contract, recovery semantics, and public
repository impact are reviewable.

## Development setup

Requirements: macOS 14+, Xcode Command Line Tools with Swift 6, Git, and `jq`
for the repository verification suite. Installation itself has no `jq` dependency.

```bash
git clone https://github.com/kohoj/longview.git
cd longview
swift test
scripts/verify-cli.sh
```

The verification script builds in an isolated scratch directory and exercises
source installation and guarded uninstallation. It must pass before a pull
request is ready.

## Architectural invariants

- `LongviewCLIKit` owns arguments, JSON envelopes, exit codes, and atomic output.
- `LongviewCapture` owns ScreenCaptureKit, layout, motion proof, and stitching.
- `LongviewCore` owns the sole vertical wheel-event emission boundary.
- Capture stays pinned to PID + WindowServer ID + frame.
- A scroll route is accepted only after captured motion verifies it.
- Foreground, pointer, and viewport state are restored and reported honestly.
- No runtime network, OCR, click, keyboard, clipboard, UI, or private API.

Do not hide unsupported behavior behind retries or app-name special cases. Add a
deep, general contract or return a structured limitation.

## Tests and fixtures

Use `LongviewFixtureApp` and synthetic pixels. Never commit screenshots or logs
from real applications, real accounts, private desktops, chats, email, or
customer data. Window titles in fixtures must be invented.

Format Swift changes before opening a pull request:

```bash
swift format format --in-place --recursive Sources Tests Fixtures Package.swift
swift format lint --strict --recursive Sources Tests Fixtures Package.swift
```

Add tests at the lowest owner:

- parser and protocol changes → `LongviewCLIKitTests`;
- stitching and output changes → `LongviewCaptureTests`;
- event and lease changes → `LongviewCoreTests`;
- install lifecycle changes → `Tests/DistributionTests/run.sh`.

## Pull requests

Keep each pull request focused, describe user-visible and contract changes, and
include exact verification commands. Maintainers retain final responsibility
for architecture, security boundary, release compatibility, and versioning.

By contributing, you agree that your contribution is licensed under MIT.
