# Agent contract — schema v2

## Discovery

Always begin with:

```bash
longview capabilities
longview doctor
longview windows [--bundle-id ID] [--include-titles]
```

Treat the returned `windowNumber` as an ephemeral lease. Re-list after App relaunch, window recreation, Space changes or a `target_window_unavailable` result.

Window titles are redacted by default because discovery output is commonly persisted in agent logs. Pass `--include-titles` only when title text is needed to disambiguate a target. `doctor` is read-only and exits successfully when diagnosis completes; inspect `result.status` and `result.readiness` rather than treating `ok=true` as full readiness.

## Recommended decision policy

```text
if one frame is enough:
    longshot --max-frames 1 --window-id ID
else if user interaction must never be disturbed:
    longshot --focus-policy background-only --window-id ID
else:
    longshot --focus-policy background-first --window-id ID

if the App has a sidebar or nested scroll area:
    pass --region x,y,width,height and --scroll-point x,y
```

For a first integration, use 3 frames. Increase only after the result reports a valid route and overlaps.

## Result interpretation

The final NDJSON line or single JSON object has:

```json
{
  "schemaVersion": 2,
  "type": "result",
  "ok": true,
  "command": "longshot",
  "result": {
    "outputPath": "/absolute/path/context.png",
    "capturedFrameCount": 3,
    "scrollRoute": "accessibility-value",
    "stopReason": "frame-limit-reached",
    "targetWasActivated": false,
    "pointerWasMoved": false,
    "viewportRestorationAttempted": true,
    "viewportRestorationSucceeded": true,
    "environmentRestorationSucceeded": true
  }
}
```

`ok=true` means the artifact was generated and atomically committed. Agents must still inspect restoration booleans before beginning another external-state mutation.

Routes:

- `none`: single frame; no scrolling.
- `accessibility-value`: background AX scrollbar action/value.
- `pid-event`: background PID wheel event verified by capture.
- `foreground-event`: global wheel event with foreground lease.

Stop reasons:

- `single-frame`;
- `frame-limit-reached`;
- `end-reached` (next mutation produced no plausible document motion).

## Retry rules

| Error code | Agent action |
|---|---|
| `background_scroll_unavailable` | Retry with `background-first` only if temporary focus is acceptable |
| `foreground_window_unavailable` | Move/show the window on the active Space; do not blind-retry |
| `target_window_unavailable` | Re-run `windows`, obtain a current ID |
| `target_window_ambiguous` | Pass one explicit `--window-id` |
| `target_changed` | Re-resolve target; do not reuse the old lease |
| `profile_unavailable` | Use `auto`, `full`, or an explicit normalized region |
| `accessibility_permission_missing` | Request host permission; retry after host restart if macOS requires it |
| `screen_capture_permission_missing` | Request Screen Recording permission |
| `output_exists` | Choose a new path or deliberately pass `--force` |

Do not retry exit 69/75 in a tight loop. External state or parameters must change first.

## Output discipline

- Reserve stdout for JSON/NDJSON and stderr for the one terminal error envelope.
- Never use `--pretty` in an agent parser.
- Do not pass `--output -`.
- Verify `schemaVersion == 2` before decoding fields.
- Prefer absolute output paths.
- Use `--force` only when replacing the exact artifact is intentional.

## Region calibration

Normalized coordinates use the captured window image:

```text
x,y,width,height where each component is between 0 and 1
```

Example: ignore a 20% left sidebar and a 10% bottom composer:

```bash
longview longshot \
  --output /tmp/context.png \
  --window-id 42 \
  --region 0.20,0.00,0.80,0.90 \
  --scroll-point 0.65,0.50
```

The scroll point should lie inside the desired scroll container, not merely inside the window.
