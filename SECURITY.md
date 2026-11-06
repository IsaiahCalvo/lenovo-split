# Security and privacy

This experimental app uses private macOS display APIs and a verified dock RAM change. It is not a firmware updater. Unknown firmware and configuration layouts must remain blocked.

There is no network client or analytics. Screen frames stay local. Accessibility is optional and window fitting is restricted to explicitly configured app bundle IDs. The separate, opt-in native Dock click handler uses the existing Accessibility grant to minimize or restore the app whose Dock tile the user clicks. It stores only window metadata in memory for restore, and never logs window titles or reads document contents. It is built in and requires no companion app. Turning it off removes the mouse monitor and cancels queued work.

Report issues privately through GitHub private vulnerability reporting if available. Do not attach credentials, raw I/O Registry dumps, monitor serials, screenshots of private windows or firmware images to public issues. If private reporting is unavailable, open a minimal issue asking for a private contact without disclosing the vulnerability or private data.

Window recovery is separately configurable. With Accessibility, it reads and changes standard desktop window geometry for regular apps, remembers rectangles and process/window IDs in memory, and skips minimized/fullscreen windows. This access is wider than the two-app fitting allowlist, and supports the explicit all-app window-recovery feature. It does not log window titles or transmit data.
