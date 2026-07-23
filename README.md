# Longview

**See beyond the viewport.**

[简体中文](README.zh-CN.md)

[![CI](https://github.com/kohoj/longview/actions/workflows/ci.yml/badge.svg)](https://github.com/kohoj/longview/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-0b7285.svg)](LICENSE)

Longview is an offline, UI-free macOS CLI that lets AI agents capture a complete
scrollable window as one PNG. It targets a stable WindowServer window, captures
with a continuous ScreenCaptureKit stream, drives public scrolling APIs with a
capture-verified adaptive pacer, stitches verified overlaps, and restores any
state it temporarily changed.

Longview is not a general computer-control framework. The runtime contains no
network client, OCR, click, keyboard, clipboard, menu bar, or hidden private API.

## Quick start

Requirements: macOS 14 or newer and Swift 6 from Xcode Command Line Tools.

```bash
xcode-select --install              # skip if Swift is already installed
git clone https://github.com/kohoj/longview.git
cd longview
./scripts/install.sh
export PATH="$HOME/.local/bin:$PATH" # only if ~/.local/bin is not on PATH
longview doctor --pretty
```

The installer builds locally, never invokes `sudo`, never edits shell files, and
writes a machine-readable receipt under `~/.local/share/longview`.

## First longshot

```bash
# 1. Inspect permissions and runtime readiness without prompting.
longview doctor --pretty

# 2. Enumerate shareable windows without activating them.
# Titles are private by default; opt in only when needed for selection.
longview windows
longview windows --bundle-id com.apple.Safari --include-titles

# 3. Capture one explicit window. PNG goes to disk; events stay machine-readable.
longview --events longshot \
  --window-id 49932 \
  --output "$PWD/context.png" \
  --max-frames 8 \
  --focus-policy background-first \
  --region auto
```

Success writes exactly one schema-v2 JSON result to stdout. Failure writes one
schema-v2 JSON error to stderr and returns a nonzero exit code. With `--events`,
stdout is NDJSON progress followed by the final result. PNG bytes never share a
stream with the protocol.

## What Longview can guarantee

| Situation | Behavior |
|---|---|
| ScreenCaptureKit exposes the window | Capture without bringing the app forward |
| The app exposes a writable Accessibility scrollbar | Background scroll, capture, and exact value restoration |
| The app honors PID-targeted wheel events | Background scroll only after captured motion verifies it |
| Background routes fail on the active Space | Optional temporary activation with pointer, viewport, and app restoration |
| The window is on another Space | Background capture may work; foreground fallback refuses before stealing focus |
| DRM, protected, remote, game, or noncompliant content | Structured unavailability; never fabricated success |

“Any app” means any ordinary, shareable layer-0 macOS window. Background capture
is broadly available; background scrolling is an app capability that Longview
probes at runtime.

## Longshot options

```text
--output PATH.png                         required; PNG never goes to stdout
--window-id UINT32                        precise WindowServer identity
--bundle-id ID                            target filter or default selection
--max-frames 1...100                      default: 6
--pulses-per-step 1...240                 initial adaptive step; default: 28
--direction up|down                       default: up
--focus-policy background-only|
               background-first|foreground
                                           default: background-first
--region auto|full|profile|x,y,w,h        normalized coordinates for rectangles
--scroll-point x,y                        default: 0.65,0.5
--settle-ms 100...5000                    maximum stability wait; default: 450
--no-stop-at-end                          disable no-motion termination
--force                                   atomically replace an existing file
```

Generated screenshots are created with mode `0600`. Existing symlinks are
refused. A successful result includes the selected target, scroll route, crop,
overlaps, stop reason, capture source, elapsed time, effective pixels per second,
activation and pointer effects, and both viewport and environment restoration
outcomes. Focus and pointer restoration are also reported independently so an
agent can distinguish the exact residual state.

Longshot pacing is closed-loop: event counts are only a tentative input. The
continuous stream replaces fixed sleeps, but only the settled viewport is
committed, and it must prove at least a 24% overlap. Longview accelerates when
overlap is abundant and backs off before a gap can enter the artifact.

App profiles may skip a background route already proven to be a no-op under
`background-first`; `background-only` always performs the real background probe.

## Permissions

| Command | Required permission |
|---|---|
| `doctor`, `capabilities` | None; checks are read-only and do not prompt |
| `windows`, one-frame `longshot` | Screen Recording |
| multi-frame `longshot` | Screen Recording and Accessibility |
| `target`, `scroll` | Accessibility |

For a source build, macOS normally attributes permissions to the Terminal, IDE,
or agent host that launches Longview. `doctor` reports readiness but deliberately
does not open System Settings or request permission.

## Install lifecycle

```bash
./scripts/install.sh                       # install or idempotently reinstall
./scripts/install.sh --prefix /absolute/path
./scripts/update.sh --check                # inspect the latest stable origin tag
./scripts/update.sh --to v0.3.1            # install an immutable release tag
~/.local/share/longview/uninstall.sh       # works after deleting the checkout
```

Update networking lives only in `scripts/update.sh`; the `longview` executable
remains offline. Uninstall removes only files recorded by the install receipt.
It never deletes screenshots, shell configuration, or macOS privacy grants.

## Build and verify

```bash
swift build -c release --product longview
scripts/verify-cli.sh
```

Verification covers unit and CLI contract tests, a clean source installation
lifecycle, schema v2, the macOS 14 deployment target, output privacy, the public
repository boundary, and static enforcement of the no-UI/no-OCR/no-network and
bounded-mutation architecture.

Read the [architecture](docs/architecture.md), [agent contract](docs/agent-contract.md),
[privacy model](PRIVACY.md), and [security policy](SECURITY.md) before embedding
Longview in an agent.

## Contributing

Contributions are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md). Security
issues belong in a private GitHub security advisory, not a public issue.

Longview is available under the [MIT License](LICENSE).
