# Monitor control research

Checked 2026-11-06. Research only: no monitor settings, service menus, ISP modes,
firmware, picture calibration, or refresh rates were changed.

## Goal and current result

Select the Philips 278E9Q's DisplayPort input when the ThinkPad 40AS connects,
even if its HDMI input is showing another computer. Continue to start both
split desktops once the required video inputs are available.

**Not yet working.** Lenovo Split already handles the later appearance of a
monitor after a manual input change. It does not yet select that input itself.

## Supported controls versus firmware access

- Philips documents DDC/CI for the 278E9QJAB family, alongside VGA, HDMI and
  DisplayPort. The regional suffix of every unit has not been verified.
  [Philips specification](https://www.documents.philips.com/assets/20230608/bc662deacc9148288a2db01b00fce8eb.pdf)
- DDC/CI defines an input-source control, VCP `0x60`. The open-source macOS
  tool m1ddc implements this; a common DisplayPort value is 15. That value is
  an example, **not a verified value for this Philips through this dock**.
  [ddcutil input control](https://www.ddcutil.com/vcpinfo_output/),
  [m1ddc source and usage](https://github.com/waydabber/m1ddc)
- TV root projects and monitor firmware research exist. MonitorDarkly, for
  example, targets a Dell 2410U; the linked Philips TV work targets a
  49PUS7503/12 with a different software platform. Neither establishes a
  working method for this Philips desktop monitor or the ViewSonic VA2446.
  [MonitorDarkly](https://github.com/RedBalloonShenanigans/MonitorDarkly),
  [Philips TV research](https://github.com/saidsurucu/philips-tpm171e-root)
- Scaler firmware access is specific to the controller and board. No supported
  root shell, verified firmware modification, exact board identification, or
  verified service-menu optimization was found for these two units. A model
  name or EDID alone does not identify a compatible firmware image.

Normal input control does not require rooting the monitor. No firmware or
service-mode work is needed to test DDC/CI input selection.

## Local read-only findings

- Built m1ddc from its official source, outside the app repository. It is a
  research tool, not a runtime dependency of Lenovo Split.
- Its ordinary display discovery did not identify either physical monitor
  by name on this split setup; it listed two unknown displays. This is not
  proof that either monitor lacks DDC/CI.
- Located exactly one external `DCPAVServiceProxy` and submitted only a
  standard **Get VCP `0x60`** request through `IOAVServiceWriteI2C`, using
  chip address `0x37` and source address `0x51`. A Get request writes a query
  packet to the bus; it does not set the monitor input.
- The query returned `0xe0114000` before the reply-read step. No input-source
  response was obtained, so no Set VCP request was sent. No input values,
  brightness, contrast, firmware or service registers were changed.
- The app's successful DisplayPort connection to the dock's Synaptics mailbox
  does **not** prove the same API can reach each downstream monitor's DDC bus.
  Those are different targets and routes.

The MonitorControl/BetterDisplay maintainer documents DDC limitations with
MST docks. This is consistent with the failed query, but does not rule out a
custom, correctly addressed downstream path for this exact controller.
[Maintainer's MST discussion](https://github.com/MonitorControl/MonitorControl/discussions/1595)

## What would establish automatic switching

1. Reach the Philips specifically through a documented or independently
   verified downstream DDC route. Validate response framing, feature code,
   result and checksum; an all-zero or stale reply is not success.
2. Read the supported input choices and current source. Repeat while the
   Philips shows HDMI from the other computer. Some monitors expose control
   only on their active input; this unit's behaviour remains unknown.
3. If that works, test one ordinary DisplayPort input-selection command with
   the user expecting the other machine's picture to be replaced.
4. Only after a real pass, add a preference to claim this Philips on dock
   connection, with bounded retries, monitor identity checks and manual
   fallback. Do not switch the shared monitor on every health check.

If the Philips does not answer while DisplayPort is inactive, a Mac-only
DDC command cannot reliably claim it over that inactive connection. A monitor
input-priority setting, another verified control route, or cooperation from
the currently active HDMI host would then be needed. None is assumed present.
The full Philips OSD/input-priority behaviour and downstream MST DDC route
remain open questions. No extra computer or hardware is assumed for this app.
