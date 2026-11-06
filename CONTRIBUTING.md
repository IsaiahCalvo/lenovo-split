# Contributing

Build with the current Xcode/Swift tools on macOS. Keep hardware checks narrow and all changes to dock memory behind the existing allowlist. Do not loosen chip, firmware or configuration checks to make an unknown dock pass.

## Validation

- Run `swift test -c release` in `app/` and build the signed app bundle.
- Test the menu panel: click outside, click Split again, press Escape, and switch apps. It must close and reopen reliably.
- Identify each screen, move a rectangle, check pointer travel, let one preview time out, then keep a layout and reconnect. The hidden wide output must never appear in the editor.
- Connect the Mac while a shared monitor is on another input. Wait more than 30 seconds, select its dock input, and check recovery. Repeat in both directions while running. Test USB reconnect, sleep/wake and stopping auto-connect.
- Toggle the custom app bars: one per usable screen, none on the hidden output; test launching an app and removal when toggled off or disconnected. Do not describe these bars as native Dock duplication.
- Check window fitting with large desktop windows in the allowlisted apps. True fullscreen, minimized, small and tiled windows must stay untouched.
- Keep raw device data private. Compatibility reports need OS, Mac model, dock model/firmware, resolution, ports, selected inputs and observed behavior, not serials or complete system dumps.

## Scope

Physical monitor metadata can be hidden by the combined output. Keep virtual panel slots stable, expose identification and manual labels, and state uncertainty rather than inventing physical monitor names. Add a new hardware profile only with a reviewed protocol change and real hardware evidence.

No cloud service, telemetry, entitlement expansion or extra app access should be added as part of a routine fix. Window-fitting scope is explicit. Keep license notices from WD19 Split and fwupd intact.

## Publishing hygiene

Only allowlisted source, scripts and docs belong in Git. Run `scripts/check_secrets.sh --staged` before a commit and `--all` before publishing. Use a GitHub noreply email. Never commit local preferences, `.secret-patterns`, logs, system dumps, signing files, media, firmware or builds.
