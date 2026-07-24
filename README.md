# DockMover

A lightweight macOS menu bar utility that keeps your Dock's app icons in a consistent order as apps open and close.

<img width="1512" height="982" alt="DockMover screenshot" src="https://github.com/user-attachments/assets/b5bddcbb-d9eb-4c62-ac25-e0850eaa97bc" />

## What it does

macOS reorders Dock icons for running apps as you launch and quit them, so your Dock rarely looks the same twice. DockMover fixes that.

You define a **target Dock** — the layout you'd want if all of your apps were running at once. DockMover then arranges the apps that are actually open to follow that target layout as closely as possible, keeping everything in a predictable place no matter what's running.

## Features

- **Target ("fake") Dock layout** — set the ideal order once; DockMover keeps the real Dock matching it.
- **Automatic** — reapplies the layout as apps launch and quit.
- **Drag-and-drop editing** — reorder slots directly in the settings window.
- **Stackable gaps** — optionally let adjacent empty slots combine into larger gaps.
- **Global shortcut** — open the settings window from anywhere with a keyboard shortcut you choose.
- **Undo & Apply Saved** — step back changes or reapply your saved layout on demand.
- **Menu bar only** — runs quietly as a menu bar item with no Dock icon of its own.

## Requirements

- macOS 13.0 (Ventura) or later
- Xcode 15 or later (to build from source)

## Build from source

```bash
git clone https://github.com/hreinssondev/DockMover.git
cd DockMover
open DockMover.xcodeproj
```

Then build and run the `DockMover` target (⌘R) in Xcode.

## Usage

1. Launch DockMover — it appears as an icon in the menu bar.
2. Open the settings window (from the menu bar item or your chosen shortcut).
3. Add the apps you want managed and drag them into your preferred order to define the target Dock.
4. Click **Save target dock**. DockMover keeps your real Dock in that order as apps come and go.

## License

Released under the [MIT License](LICENSE).
