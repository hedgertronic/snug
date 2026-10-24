# Snug

Snug is a macOS screenshot app. Press one shortcut, point at what you want, and Snug picks the element under the pointer (a window, a sidebar row, a button, a table) so one click or Return copies it. The same overlay copies text from images, records the screen, and hands a capture to an AI agent.

Snug runs entirely on your Mac. Captures are not uploaded. Requires Apple Silicon and macOS 26 or later.

## Install

Snug is not distributed yet. Build it from source (see "For developers"), then open `build/Snug.app`. It lives in the menu bar and has no Dock icon. The app is signed for local development only; it is not notarized.

Open it once and the first-run screen walks through the permissions below. The default capture shortcut is Control-Shift-Space; change it in Settings > General.

## Permissions

- **Screen Recording (required).** Snug freezes the display under the pointer so you can choose from it, and records the screen on request.
- **Accessibility (recommended).** Lets Snug read the layout of other apps, so it can highlight buttons, sidebars and rows exactly instead of guessing from pixels. Without it Snug falls back to edge detection.

## Using it

The overlay opens in Capture mode. Press `?` in the overlay for the full key list.

**Capture** (A): hover to highlight an element, then click or press Return to copy it. Drag to draw an area (edges snap to nearby boundaries; hold Option to keep the exact rectangle). Esc closes the overlay.

**Text** (T): select text in the frozen image as you would on a web page (macOS Live Text), then Return to copy it.

| Key | Action |
| --- | --- |
| Return | Copy the selection, or the hovered element |
| Cmd-Return | Copy for an agent (see below) |
| Up / Down | Walk the hover out to the parent element, or back in |
| Left / Right | Hover the neighboring element |
| Tab | With a selection: focus a corner for its radius |
| arrows | Move the selection (Shift: 10 px) |
| Option-arrows | Grow or shrink a side |
| F | Full screen |
| W | The window under the pointer |
| S | Snap on or off |
| M | Frame on or off (window shadow or padded card) |
| O | Rounded corners on or off |
| G | Scrolling capture of the selection |
| V | Record the selection (V or Return starts) |
| K | Cut out the subject |
| C / Shift-C | Copy the color under the pointer / change its format |
| Cmd-S / Cmd-Shift-S | Save / Save As |
| L / R / X | Loupe / rulers / crosshair |

The menu bar icon also offers Capture, Capture Text, Settings, About and Quit.

## Agent handoff

Cmd-Return copies the capture for an agent: the pixels at full resolution plus a manifest of what was under the pointer (app, window, element). Paste it into your agent chat. The paste carries a short reference line with a capture id.

To let an agent read it, add Snug's MCP server to Claude Code:

```sh
claude mcp add snug -- /path/to/Snug.app/Contents/MacOS/Snug --mcp
```

Settings > Agent shows this command with the real path and a Copy button. The server is read-only and has two tools, `get_capture` and `zoom`. Snug never captures for an agent; it only serves what you copied. Only the last capture is kept. "Clear last capture" in Settings > Agent removes it. Captures are stored in `~/Library/Application Support/Snug/Agent/`.

## Settings

- **General:** capture shortcut, After capture (Copy, or Copy and save), save folder, Open at login, permission status.
- **Appearance:** overlay look (System, Light, Dark), highlight color, fill, fade and glow, and the toast's preview, position and lifetime.
- **Keys:** a reference of every overlay key. Rebinding is not available yet.
- **Agent:** the MCP command and Clear last capture.

Toggles you flip in the overlay (Loupe, Rulers, Frame, Rounded, Snap, and others) are remembered.

## For developers

Xcode with a macOS 26 SDK and Swift 6.2 or later. No third-party packages.

```sh
SNUG_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" uv run scripts/build.py   # builds build/Snug.app, the lab app and build/ScreenshotBench
swift test --disable-sandbox    # unit tests
```

`scripts/build.py` signs Snug with the code signing identity in `SNUG_SIGNING_IDENTITY` (`security find-identity -v -p codesigning` lists yours) and stops if it is unset. A fixed identity keeps the Screen Recording permission across rebuilds. Test fixtures are in `Tests/Fixtures` and `Tests/ScreenshotCoreTests/Fixtures`. The repo also holds the original detector lab (`ScreenshotLab`) and `ScreenshotBench`, the detector benchmark:

```sh
build/ScreenshotBench suite --manifest Tests/Fixtures/evaluation/public-suite.json --baseline Tests/Fixtures/evaluation/baselines/public-suite.json --output DIR
```

Run `build/ScreenshotBench` with no arguments for every subcommand.

## Support

Snug is free. If it saves you time, [buy me a bag of sunflower seeds](https://ko-fi.com/hedgertronic).

## License

MIT. See `LICENSE`.
