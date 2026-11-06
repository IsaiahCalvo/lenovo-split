# App source

See the root [README](../README.md) for Lenovo Split setup and limits.

- `Sources/LenovoDock`: verified ThinkPad 40AS DisplayPort mailbox backend.
- `Sources/LenovoSplit`: app lifecycle, recovery, capture, layout editor, identification and optional window fitting.
- `Sources/DisplayLayout`: pure layout model and placement validation.
- `Tests/DisplayLayoutTests`: geometry and persistence tests.
- `Sources/VirtualDisplay`: upstream private macOS virtual-display bridge.
- `Sources/WD19Split`, `DockCore`, `dockctl`: original Dell-specific targets, retained for reference. Not called by Lenovo Split.

Build the installable bundle with `../script/build_and_run.sh --build-only`; using `swift run` alone does not provide the stable app identity used for privacy permissions.
