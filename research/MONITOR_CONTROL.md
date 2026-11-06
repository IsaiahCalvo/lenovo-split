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

## Brightness and audio references (2026-11-06)

This is an implementation assessment, not a shipped monitor-control feature.
No live app, display layout, picture level, audio route or volume was changed.

Reviewed sources:

- [MonitorControl](https://github.com/MonitorControl/MonitorControl), commit
  `7cfe64500d19cbbcbf82121a91c826f658a403bd`. MIT license; reuse requires retaining
  its copyright and permission notice. Relevant files: `Model/Display.swift`
  (gamma/shade dimming), `Model/OtherDisplay.swift` (monitor controls), and
  `Support/Arm64DDC.swift` (Apple Silicon transport).
- [Vorssaint](https://github.com/vorssaint/vorssaint-utils), reviewed checkout
  `26d3c9e199eb3afc8f43ce8bd83210b5754421bd`. GPL-3.0-or-later. Relevant areas:
  display brightness and fallback dimming; audio output selection, per-app
  volume and routing. No GPL code has been copied into Lenovo Split.

| Proposed control | Finding on this split design | Implementation status |
| --- | --- | --- |
| Separate image dimming | Each virtual desktop already has a separate captured image layer over a black background. Applying a factor to the final panel layer can dim each output independently. | Feasible from code inspection; not implemented or physically verified. |
| True monitor backlight | Standard DDC luminance is VCP `0x10`. Requires a verified route to each physical monitor, not a virtual display ID. | Not established through this dock. |
| Monitor speaker volume/mute | Standard controls include VCP `0x62` and `0x8D`; actual support and range must be verified per monitor. This controls the speaker level, not audio routing. | Not established through this dock. |
| Audio output selection | Core Audio can list real output devices and choose among available routes. | Read-only inventory completed; no route changed. |
| Independent sound to each monitor | Two virtual video displays do not create two audio devices. Requires separately addressable endpoints and actual audio paths to both speakers. | No separate Philips/ViewSonic endpoints found in this session. |
| Per-app volume/routing | Vorssaint uses Core Audio process taps and aggregate-device/rendering infrastructure. This is a separate audio feature, not a monitor volume setting. | Research only; no taps, audio capture or aggregate devices created. |

[DDC control definitions](https://www.ddcutil.com/vcpinfo_output/),
[Apple Core Audio tap overview](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).

### Additional local evidence

A read-only luminance request was made using MonitorControl's Get VCP packet
framing and reply offset, independently of the earlier m1ddc-style input test.
The write of the query packet returned `0xe0114000`; no valid luminance reply
was obtained and no Set VCP command followed. This is a failure of the tested
route, not proof that either monitor lacks a hardware brightness control.
Speaker-volume access was not independently established.

The Core Audio inventory showed the dock's USB audio output, but no separate
Philips or ViewSonic output. That USB device exposed no standard scalar volume
control at the master, left or right output elements queried. This does not
establish that every possible device control is absent. Personal output-device
names, identifiers and current levels are deliberately omitted from this note.

The current temporary host EDID override contains only a 128-byte base block
and sets the extension count to zero. It does not advertise a CTA audio block.
That may contribute to the absence of a DisplayPort monitor-audio endpoint;
the causal link and any valid audio capability/forwarding configuration remain
unverified. Do not invent audio capabilities in the EDID to make a UI appear
supported. The current capture streams forward video only.

### Proposed first implementation

1. Add optional **Image dimming** sliders for the two physical outputs. Default
   to no dimming, and label this as software dimming rather than backlight or
   power-saving control. It can reduce the rendered image level; it cannot
   exceed the monitor's hardware brightness.
2. Apply the adjustment in the existing compositor, not by changing the Mac's
   global gamma tables. This avoids competing gamma writes with MonitorControl,
   Vorssaint, Night Shift or calibration tools. Their own adjustments can still
   combine with ours, so our dimming must remain optional and easy to reset.
3. Store levels by the existing physical-output keys, not by transient display
   IDs or left-to-right order. Reordering the desk must not swap brightness
   values. Preserve the legacy output mapping.
4. Remove all effects on stop/quit and restore only our own requested levels
   after reconnect. Provide a clear reset to an undimmed image and avoid an
   accidental fully black desktop.
5. Add per-feature capability states before hardware controls: available,
   software-only, not reachable, or not yet tested. Validate every DDC reply and
   require verified monitor identity/port routing before enabling writes. A
   successful API call alone is not proof of a changed backlight or volume.
6. Keep keyboard/media-key interception off by default and avoid registering
   duplicate handlers when another controller owns those keys. Never disable
   another app or overwrite its settings. Per-device audio controls should be
   shown only for real supported devices; a shared output must not masquerade
   as two independently controlled monitor speakers.

No MonitorControl runtime dependency is needed. Any future adapted MIT code
must include its notices; Vorssaint remains a behavioural reference unless the
project's licensing is explicitly changed.
