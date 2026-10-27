# Snug

**Screenshots that fit like a glove.**

Hover to grab any window or element, or drag a rough box and Snug snaps it tight. Press Return to copy. Snug is a menu bar screenshot app for macOS 26 or later, built with Swift and AppKit.

## Install and use

[Download Snug](https://snugshot.app), open it, and allow Screen Recording. Accessibility permission helps Snug find elements and read text accurately; without it, Snug uses pixels and OCR.

Press **Control-Shift-Space** to capture the display under your pointer. Hover and click or press Return to copy, or drag an area. Hold Option while dragging for an exact crop. Change the capture shortcut in Settings → General.

## Keys

Press `?` in the overlay for the full list.

| Key | Action |
| --- | --- |
| Return / Cmd-Return | Copy / copy for an agent |
| Cmd-S / Cmd-Shift-S | Save / Save As |
| Esc | Back out of the current selection or mode; press again to close |
| A / T | Capture / Text mode |
| Up / Down; Left / Right | Hover parent or child; neighboring element |
| Arrows / Shift-arrows | Move a selection 1 / 10 pixels |
| Option-arrows / Option-Cmd-arrows | Grow / shrink a side |
| F / W | Full screen / window |
| E / Shift-click | Edit the hovered element |
| S / M / O | Toggle snapping / frame / rounded corners |
| Tab; [ / ] | Focus a selection's corner; decrease / increase radius |
| G / V / K | Scrolling capture / recording / subject cutout |
| L / R / X | Loupe / rulers / crosshair |
| C / Shift-C | Copy color / change color format |

In Text mode, select text and press Return to copy it. With recording armed, V or Return starts; the capture shortcut stops it.

## Agent / MCP setup

Press **Cmd-Return** in Capture mode, then paste into your agent chat. Snug supplies the image and a reference to its app, window, and element context.

Settings → General → Agent → Copy Setup copies the command with your installed app's path. Or replace `/path/to/Snug.app` below:

```sh
claude mcp add snug -- /path/to/Snug.app/Contents/MacOS/Snug --mcp
codex mcp add snug -- /path/to/Snug.app/Contents/MacOS/Snug --mcp
```

For clients that use `mcpServers` JSON:

```json
{
  "mcpServers": {
    "snug": {
      "command": "/path/to/Snug.app/Contents/MacOS/Snug",
      "args": ["--mcp"]
    }
  }
}
```

The read-only tools, `get_capture` and `zoom`, serve only captures you hand over. They cannot take screenshots. Only the latest handoff is kept, in `~/Library/Application Support/Snug/Agent/`; **Clear** in the Agent settings removes it.

## Build from source

Use Xcode with the macOS 26 SDK and Swift 6.2 or later. Set your code-signing identity:

```sh
SNUG_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" python3 scripts/build.py
```

This builds `build/Snug.app` as a universal arm64 + x86_64 app. Add `--lab` to also build the developer lab app and the benchmark. Use a consistent signing identity to preserve macOS permission grants. Local builds are not notarized.

## Privacy, license, and credit

Capture processing, OCR, and subject cutouts run on-device. Snug does not upload captures. It uses Sparkle to check for and download updates. If you connect an agent, that agent can read your latest handoff and handles it under its own data policies.

[MIT licensed](LICENSE). Made by [Josh Hejka](https://hedgertronic.com/), with [Sparkle](https://sparkle-project.org/) for updates and [Fredoka](brand/fonts/OFL.txt) for the wordmark.
