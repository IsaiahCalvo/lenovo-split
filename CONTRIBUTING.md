# Contributing

Build with the current Xcode/Swift tools on macOS. Keep hardware checks narrow and all changes to dock memory behind the existing allowlist. Do not loosen chip, firmware or configuration checks to make an unknown dock pass.

## Validation

- Run `swift test -c release` in `app/` and build the signed app bundle.
- Test the menu panel: click outside, click Split again, press Escape, and switch apps. It must close and reopen reliably.
- Identify each screen, drag the middle rectangle to both ends and try all six row orders without renumbering, check pointer travel, let one preview time out, then keep a layout and reconnect. The hidden wide output must never appear in the editor.
- Connect the Mac while a shared monitor is on another input. Wait more than 30 seconds, select its dock input, and check recovery. Repeat in both directions while running. Test USB reconnect, sleep/wake and stopping auto-connect.
- For legacy profiles with Swap stored in either state (the UI toggle has been removed): Arrange names, saved labels and Identify badges must agree with the physical panel each virtual number is sent to. Verify existing physical output labels are preserved when updating.
- Test the built-in native Dock handler with other tools’ click actions disabled. Finder: background activation, minimize, restore, manual minimize then restore, drag an icon, press-and-hold, modifier-click, and toggle the feature off. Check the log confirms Lenovo Split performed the minimize/restore. Never substitute a companion app for this test. Keep MIT credits from Light Stats intact; do not embed GPL code in the MIT project.
- Put ordinary windows on both externals, unplug the host cable, work on the Mac, then reconnect. Check the windows return to their prior output or remain reachable. Test an app activated after reconnect and **Recover windows now**, with both Dock click handling and recovery enabled. Do not use a thumbnail-drag workaround as a passing result.
- Check window fitting with large desktop windows in the allowlisted apps. True fullscreen, minimized, small and tiled windows must stay untouched.
- Keep raw device data private. Compatibility reports need OS, Mac model, dock model/firmware, resolution, ports, selected inputs and observed behavior, not serials or complete system dumps.

- Test hover focus with two disposable app windows, including within one app, across apps/screens, Control held, clicks, drags, scrolling, Command-Tab, a menu, a sheet and fullscreen. Only an ordinary window beneath a resting pointer should raise. Start standalone AutoRaise after enabling this feature: the status must pause, no focus actions should run, and the external process must remain untouched. Stop that instance yourself and check fresh movement resumes hover. A harmless sleeper named AutoRaise is used by the automated detection test; do not require the real app in CI.

## Scope

Physical monitor metadata can be hidden by the combined output. Keep virtual panel slots stable, expose identification and manual labels, and state uncertainty rather than inventing physical monitor names. Add a new hardware profile only with a reviewed protocol change and real hardware evidence.

No cloud service, telemetry, entitlement expansion or extra app access should be added as part of a routine fix. Window-fitting scope is explicit. Keep license notices from WD19 Split and fwupd intact.

## Publishing hygiene

Only allowlisted source, scripts and docs belong in Git. Run `scripts/check_secrets.sh --staged` before a commit and `--all` before publishing. Use a GitHub noreply email. Never commit local preferences, `.secret-patterns`, logs, system dumps, signing files, media, firmware or builds.
