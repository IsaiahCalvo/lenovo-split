# Lenovo Split

Two independent 1920 × 1080 desktops through a Lenovo ThinkPad USB-C Dock Gen 2 (40AS), alongside an open MacBook display.

An experimental, community-built macOS app. **Not a Lenovo product or an official Lenovo solution.** Based on [WD19 Split](https://github.com/kksimp/wd19-split), with a separate backend for the Lenovo dock.

## Tested setup

- Base M3 MacBook Pro, lid open, macOS 27.2.
- ThinkPad USB-C Dock Gen 2 **40AS**, USB ID `17ef:a38f`.
- Synaptics **VMM5322**, firmware **5.05.006**, matching configuration signature.
- Two 1080p monitors, both run at **60 Hz**. Tested panels: ViewSonic VA2446 and Philips 278E9Q.

The code targets macOS 14+, but earlier OS releases and other Mac/dock/monitor combinations are **unverified**. It refuses other hub firmware/configurations. This is not a general MST driver, and does not enable arbitrary resolutions or dock models.

## Features

- Two virtual extended displays, each with its own fullscreen Space, drawn onto the two halves of the dock output.
- Starts when the dock connects; continues waiting if the second monitor selects its dock input later.
- Checks dock state and recovers after output changes. No firmware flashing.
- Menu-bar controls that dismiss on an outside click; no app icon in the Dock.
- **Identify displays:** temporary numbers on each usable screen.
- **Arrange displays:** drag rectangles, snap edges, label monitors, swap physical halves, and keep/revert a preview. Unconfirmed layouts revert after 15 seconds; confirmed layouts persist across reconnects.
- Optional **app bar on every display** with pinned Dock apps and running apps. This is a custom launcher, not a copy of Apple's Dock. It does not provide native Dock stacks, Trash, window thumbnails, or change macOS Dock settings. Windows may need resizing to leave space for it.
- Optional window fitting for **Claude and Grok Bot only**, with a separate Accessibility permission. Smaller, tiled, minimized and true fullscreen windows are left alone.

## Build and install

Requires Xcode/Swift 6 command-line tools and Python 3 for the install helper. No paid dependency, driver, kernel extension, or external Swift package is required.

```sh
git clone https://github.com/IsaiahCalvo/lenovo-split.git
cd lenovo-split
./script/build_and_run.sh --build-only
./script/install.sh
```

The install script copies the app to `~/Applications/Lenovo Split.app` and writes `~/Library/LaunchAgents/local.lenovosplit.plist`.

To start at login and watch future dock connections:

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.lenovosplit.plist
open -a "$HOME/Applications/Lenovo Split.app"
```

If the login entry is already loaded after rebuilding, quit the running app before installing, then use:

```sh
launchctl kickstart gui/$(id -u)/local.lenovosplit
```

The build uses the first local Apple Development identity, when present, to help preserve macOS permissions across rebuilds; otherwise it signs ad hoc. Override with `SIGN_ID=-` or a signing identity of your choice. It does not export certificates or keys. No notarized binary is provided: build from source.

## First setup

1. Connect both monitors to the dock. On a monitor shared with another computer, select the input wired to this dock. The app deliberately does **not** force a monitor away from its other input.
2. Open Lenovo Split. Grant Screen Recording when requested; then start the screens. On newer macOS releases the OS may rename permission groups.
3. Click **Identify displays**. Numbers 1 and 2 identify the virtual panels; 3 identifies the built-in display when present.
4. Open **Arrange displays**. If the physical monitors have the numbers reversed, use **Swap which physical monitor shows display 1 and 2**. Then drag the rectangles to match the desk and select **Apply layout → Keep layout**.
5. Give the screens names if desired. The names shown in macOS update on the next split startup. The app can identify its own virtual panels reliably; it does not pretend it can always retrieve both physical monitors' names through the combined signal.
6. Optional: turn on the app bars. Optional: grant Accessibility for window fitting. These are separate features.

The built-in display remains the main screen while present. The hidden wide transport output is deliberately excluded from the editor. Arrange the usable displays in Lenovo Split rather than moving its hidden output in System Settings.

## Shared monitor inputs and recovery

A monitor set to HDMI from another computer may stop advertising its DisplayPort connection to the dock. The app cannot draw on that panel until it selects the dock input. It keeps retrying with backoff rather than giving up after a fixed short window, and watches USB, display and wake events. A low-frequency check also detects dock mode/output changes and capture errors. Two unhealthy checks precede a restart to avoid rebuilding for a brief transition.

Health checks do not rewrite the split mode or refresh the host EDID. Those changes happen only when preparing a split. Hardware input switching and sleep/wake must still be tested for each setup; the current hardware support list is intentionally narrow.

## How it works

The Mac sends one 3840 × 1080 stream. The dock's existing split function sends a 1920 × 1080 half to each monitor. Two `CGVirtualDisplay` desktops are captured with ScreenCaptureKit and drawn onto those halves. The physical wide output is parked beside the usable desktops and excluded from normal pointer travel.

The Lenovo backend uses macOS's private DisplayPort APIs to reach the Synaptics remote-control mailbox. It checks the USB device, chip, firmware, configuration signature and port widths before changing **one byte in volatile hub RAM at `0x1740`** from mode 3 to mode 2. It then verifies the value. No firmware, flash, HDCP, encrypted security region, or SIP setting is changed.

When needed after reconnect, a temporary **Mac-side EDID override** adds the measured 3840 × 1080 @ 60 Hz timing. It does not alter a monitor's stored EDID or dock firmware. The private mode table selects the wide mode. OS updates can break these private APIs.

## Limits and privacy

- Screen Recording is needed for rendering; screen frames stay on this Mac. The app has no networking, analytics, account, or remote logging.
- Protected video may be black. The app respects macOS content protection.
- Capture adds latency and CPU/GPU work; this is not direct native scanout of two independent streams.
- The app bars read local app names, icons and Dock-pinned app URLs. Clicking an icon asks macOS to open/activate the app. They do not inspect other app contents or list individual windows.
- Optional window fitting queries geometry only for the two allowlisted apps. It does not grant the app permission by itself or enlarge the allowlist automatically.
- Layouts, monitor labels and preferences stay in the local user preferences. Logs contain state and geometry, not screen images or chat contents. Review logs before sharing.
- Quitting removes the virtual displays and restores saved physical display positions when those displays remain online. The volatile dock split can remain until the dock resets; stop is not a firmware/default reset.
- Source includes no device dumps, personal preference files, certificates, credentials, compiled apps, vendor firmware or disassembly.

## Develop and test

```sh
cd app
swift test -c release
cd ..
./script/build_and_run.sh --build-only
```

Layout tests check overlap, reachability, snapping, coordinate normalization and persistence. They do not prove hardware compatibility. See [CONTRIBUTING.md](CONTRIBUTING.md) for the manual hardware checks.

The upstream Dell targets remain in the source tree for attribution and reference; Lenovo Split does not call their backend. [NOTICE.md](NOTICE.md) lists upstream credit and license details.

## Uninstall

```sh
./script/uninstall.sh
```

This stops the app, removes its login entry and installed bundle, and leaves preferences available for a later reinstall. It does not flash/reset the dock or change monitor input selection. macOS privacy grants can be removed in System Settings.

## License

[MIT](LICENSE). Original WD19 Split copyright is retained. Lenovo, ThinkPad, ViewSonic, Philips, Apple and Synaptics names describe compatibility; this project is not affiliated with those companies.
