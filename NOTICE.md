# Notices

## WD19 Split

Lenovo Split is derived from [WD19 Split](https://github.com/kksimp/wd19-split),
Copyright (c) 2026 kksimp, licensed under MIT. The virtual-display bridge,
mode-table access, screen-capture renderer and some build structure derive
from that project. Its copyright and MIT license are retained. The Lenovo
DisplayPort backend and new setup/recovery controls are additions.

## Light Stats

The built-in native-Dock click handling adapts the Dock click policy, gesture
checks, Dock icon hit testing and window-minimize retry flow from
[Light Stats](https://github.com/EvilIrving/light-stats), at commit
`8e33bfe643bb339ee254ce618e17e24af63f0d91`:

- `Light Stats/Services/DockClickPolicy.swift`
- `Light Stats/Services/DockClickService.swift`
- `Light Stats/Services/DockGeometry.swift`
- `Light Stats/Services/WindowMinimizeService.swift`

Copyright (c) 2026 EvilIrving, MIT license. The full MIT permission and warranty
notice and copyright are retained in LICENSE and in the installed app bundle.
The adapted service is compiled into Lenovo Split; it does not call or require
the Light Stats app, DockDoor, or Vorssaint. No GPL code from those apps is bundled.

## fwupd

The dock and MST hub protocol in `app/Sources/DockCore` (HID-to-I2C bridge
commands, embedded-controller commands, VMM5331 "Panamera" register addresses
and remote-control command flow) follows the `dell-dock` plugin of
[fwupd](https://github.com/fwupd/fwupd):

- `plugins/dell-dock/fu-dell-dock-hid.c` — Copyright 2018 Realtek Semiconductor
  Corporation, Copyright 2018 Dell Inc.
- `plugins/dell-dock/fu-dell-dock-ec.c`, `fu-dell-dock-mst.c` — Copyright Dell Inc.

Those files are licensed `LGPL-2.1-or-later OR MIT`; this project uses them
under the MIT option.

## Trademarks

Lenovo and ThinkPad are trademarks of Lenovo. ViewSonic and Philips names
are used only to describe tested panels. This is not a Lenovo-supported product.
Dell and WD19 are trademarks of Dell Inc. Synaptics and ViewXpand are
trademarks of Synaptics Incorporated. Apple, Mac and macOS are trademarks of
Apple Inc. They are used here only to describe compatibility.

## Firmware

No Dell, Synaptics or other vendor firmware, firmware dumps or derived
disassembly is included in this repository.
