# MiniLunar 🌙

A macOS menu bar utility to disconnect the built-in display on MacBook laptops when using an external monitor.

## Features

- **Toggle built-in display** — Disconnect/reconnect the MacBook's built-in LCD with one click
- **Auto BlackOut** — Automatically disconnects the built-in display when an external display is detected, and reconnects when the external is removed
- **Emergency hotkey** — Press `Cmd+Alt+Shift+1` to toggle the display (requires Accessibility permission)
- **State persistence** — Remembers the display state across restarts
- **DisplayLink detection** — Warns if DisplayLink drivers are active, as they may conflict

## Requirements

- macOS 13+ (Ventura or later)
- Apple Silicon (M1/M2/M3/M4) or Intel MacBook
- An external display connected to use the disconnect feature

## Installation

```bash
make install
```

This builds the app and installs it to `~/Applications/MiniLunar.app`.

## Usage

1. Launch MiniLunar — it appears as a 🌙 icon in the menu bar
2. Click the icon and select **Disconnect Built-in Display**
3. To reconnect, click the icon again and select **Reconnect Built-in Display**
4. Enable **Auto BlackOut** for automatic management when connecting/disconnecting external displays

## Build from source

```bash
make build      # Build the binary
make bundle     # Build + create .app bundle
make run        # Build + bundle + launch
```

## How it works

MiniLunar uses a private SkyLight API (`CGSConfigureDisplayEnabled`) to remove the built-in display from the compositing pipeline, which effectively turns it off without putting the MacBook to sleep. This is the same approach used by tools like [Lunar](https://lunar.fyi/) and [mac-display-toggle](https://github.com/nriley/mac-display-toggle).

## License

Personal utility — provided as-is.
