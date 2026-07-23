# Privacy

Longview captures screen content. Treat every output as potentially sensitive.

## Runtime data flow

The `longview` executable:

- captures only the selected WindowServer window;
- processes frames and overlap data locally in memory;
- writes the requested PNG to the explicit output path;
- contains no network client, telemetry, analytics, OCR, clipboard access, or
  background upload path;
- creates screenshots with owner-only `0600` permissions;
- redacts window titles from `windows` output unless `--include-titles` is used.

Longview does not retain a second copy of a screenshot. It does return metadata
such as application identity, window ID, frame, output path, route, and recovery
status. Calling agents and terminals may log that metadata or independently
upload the resulting PNG; their privacy policies apply after Longview returns.

## Permissions

Source builds normally receive Screen Recording and Accessibility permission
through the Terminal, IDE, or agent host that launches them. Longview never
prompts automatically, edits the TCC database, or opens System Settings.

## Repository scripts

`install.sh`, `uninstall.sh`, and the runtime are offline. `update.sh` contacts
the checkout's Git `origin` only when explicitly invoked. No lifecycle script
modifies shell startup files or removes user screenshots.

## Responsible use

Do not capture windows you are not authorized to access. Prefer an explicit
`--window-id`, keep title enumeration disabled, inspect restoration fields, and
delete outputs according to your own retention policy.
