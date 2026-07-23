# Architecture

## Product thesis

`longview` is a narrow native capability beneath an agent, not an agent and not a GUI automation framework. Its deep interface is:

```text
explicit window target + bounded capture policy -> PNG artifact + machine-verifiable receipt
```

The implementation separates capture from scrolling because macOS grants them different powers. ScreenCaptureKit can capture a selected window without making it frontmost; changing that window's viewport depends on what the target App exposes.

## Ownership boundaries

```mermaid
flowchart LR
    A["Agent / CLI parser"] --> B["WindowTargetResolver"]
    B --> C["WindowCaptureSession"]
    B --> D["LongScreenshotCoordinator"]
    D --> E["AX scrollbar route"]
    D --> F["PID wheel route"]
    D --> G["Foreground transaction route"]
    E --> C
    F --> C
    G --> C
    C --> H["Motion verifier"]
    H --> I["Region resolver + stitcher"]
    I --> J["Atomic PNG writer + schema v2 receipt"]
```

- `WindowTargetResolver` owns discovery and the PID/windowID/frame identity tuple.
- `WindowCaptureSession` owns `SCContentFilter(desktopIndependentWindow:)` and never resolves "current foreground" implicitly.
- `WindowScrollSessions` owns every longshot mutation and restoration action.
- `SystemScrollEventPoster` is the only module allowed to construct and post wheel events.
- `LongScreenshotStitcher` owns motion confidence, overlap, document ordering, transparent-edge composition and crop semantics.
- `LongviewCLIKit` owns stable arguments, JSON envelopes, exit codes and atomic output.

The test-only AppKit fixture is a SwiftPM target but not a package product and cannot enter the distributed CLI.

## Route ladder

The coordinator captures an immutable first frame, then probes routes in order:

1. AX scrollbar action/value: mutate a live scrollbar without activation, capture, verify vertical document motion.
2. PID-targeted wheel: post directly to the selected PID and coordinate, capture, verify motion.
3. Foreground transaction: only if policy permits and the exact window is visible on the active Space; activate, place pointer, post global wheel, capture and verify.

A route is selected only after observed pixels prove motion. Event-post success is not considered scroll success.

## Transaction and restoration

```mermaid
stateDiagram-v2
    [*] --> Resolve
    Resolve --> CaptureInitial
    CaptureInitial --> ProbeRoute
    ProbeRoute --> CaptureFrames: verified motion
    ProbeRoute --> Restore: boundary / no more frames
    CaptureFrames --> Restore: frame limit / end / error / cancellation
    Restore --> VerifyRestore
    VerifyRestore --> Stitch
    Stitch --> AtomicCommit
    AtomicCommit --> [*]
```

The transaction records original scrollbar value, frontmost application and pointer location before mutation. Restoration order is deliberate:

1. reacquire the target lease only when the CLI itself activated it;
2. restore the viewport;
3. capture again and compare with the initial frame;
4. restore pointer and original frontmost application;
5. emit the receipt.

Cancellation does not suppress cleanup delays or inverse events.

## Target identity

`windowID` is the primary key. Bundle identifier is optional metadata and a useful discovery filter. This permits agent-created executables and development Apps without an application bundle to participate.

The lease rejects changes to:

- owner PID;
- WindowServer window ID;
- window frame beyond a small compositor tolerance;
- frontmost PID for global events;
- pointer containment for global events.

## Crop and stitch policy

- Known profiles may define an exact content rectangle and one fixed header.
- Generic `auto` removes only fixed top/bottom chrome. It intentionally does not infer horizontal sidebars from frame difference because margins, avatars and line numbers can look static.
- Explicit normalized rectangles are the escape hatch for nested scroll regions.
- Scroll steps remain smaller than a viewport so adjacent frames overlap.
- Overlap is computed from informative pixels, not raw full-frame equality.
- Transparent window corners are composited over the dominant document background rather than cropped from the final page.

## Why no private window automation

Private SkyLight/CGS calls could switch Spaces or inject window-targeted events more aggressively, but they would create OS-version fragility, signing risk and an unreviewable trust boundary. The public-API product instead reports the exact unsupported state:

- capture unavailable;
- background scroll unavailable;
- foreground window unavailable on active Space;
- target lease changed;
- restoration unverified.

This is a stronger agent primitive because failure is stable and machine-actionable.

## Extension points

New App support should arrive through one of three bounded additions:

1. a crop profile keyed by bundle ID;
2. a public, capture-verified `WindowScrollSession` strategy;
3. agent-supplied `--region` and `--scroll-point` values.

No App-specific behavior belongs in the CLI parser, capture session or event poster.
