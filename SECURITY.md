# Security policy

## Supported versions

Security fixes are made on `main` and released in the newest stable `vX.Y.Z`
tag. Older pre-1.0 releases are not maintained after a replacement ships.

## Reporting a vulnerability

Do not open a public issue for a vulnerability or include real screenshots,
window titles, access tokens, personal data, or exploit details in public.

Use the repository's **Security → Report a vulnerability** flow to open a
private GitHub security advisory. Include the affected version, macOS version,
architecture, minimal reproduction, impact, and a synthetic fixture whenever
possible. Maintainers will acknowledge the report, reproduce it privately, and
coordinate disclosure after a fix is available.

## Security boundary

Longview deliberately permits only:

- ScreenCaptureKit capture of an explicit shareable window;
- Accessibility scrollbar action/value changes;
- bounded vertical pixel-scroll events;
- narrowly leased temporary foreground activation and pointer movement when
  policy allows, followed by restoration and capture verification.

The runtime must not gain network, OCR, click, keyboard, clipboard, arbitrary
AppleScript, shell execution, private framework, or hidden UI capability.
Changes to this boundary require explicit architecture review and tests.

Generated PNG files must remain owner-only, output symlinks must be refused,
and real application data must never enter tests or the public repository.
