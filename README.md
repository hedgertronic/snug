# Snug

Snug is a macOS screenshot app. Press one shortcut, point at what you want, and Snug picks the element under the pointer (a window, a sidebar row, a button, a table) so one click or Return copies it. The same overlay copies text from images, records the screen, and hands a capture to an AI agent.

Snug runs entirely on your Mac. Captures are not uploaded; the only network request is the update check, which reads Snug's appcast on GitHub. Requires Apple Silicon and macOS 26 or later.

## Install

Snug is not distributed yet. Build it from source (see "For developers"), then open `build/Snug.app`. It lives in the menu bar and has no Dock icon. The app is signed for local development only; it is not notarized.

Open it once and the first-run screen walks through the permissions below. The default capture shortcut is Control-Shift-Space; change it in Settings > General.

## Permissions

- **Screen Recording (required).** Snug freezes the display under the pointer so you can choose from it, and records the screen on request.
- **Accessibility (recommended).** Lets Snug read the layout of other apps, so it can highlight buttons, sidebars and rows exactly instead of guessing from pixels, and lets Text mode copy their text exactly instead of reading it with OCR. Without it Snug falls back to edge detection and OCR.

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

The menu bar icon also offers Capture, Capture Text, Settings, About, Check for Updates and Quit.

## Agent handoff

Cmd-Return copies the capture for an agent: the pixels at full resolution plus a manifest of what was under the pointer (app, window, element). Paste it into your agent chat. The paste carries a short reference line with a capture id.

To let an agent read it, add Snug's MCP server to Claude Code:

```sh
claude mcp add snug -- /path/to/Snug.app/Contents/MacOS/Snug --mcp
```

Settings > Agent shows this command with the real path and a Copy button. The server is read-only and has two tools, `get_capture` and `zoom`. Snug never captures for an agent; it only serves what you copied. Only the last capture is kept. "Clear last capture" in Settings > Agent removes it. Captures are stored in `~/Library/Application Support/Snug/Agent/`.

## Settings

- **General:** capture shortcut, save folder (where Cmd-S saves and Save As starts), Open at login, permission status.
- **Appearance:** overlay look (System, Light, Dark), highlight color, fill, fade and glow, and the toast's preview, position and lifetime.
- **Keys:** a reference of every overlay key. Rebinding is not available yet.
- **Agent:** the MCP command and Clear last capture.

Toggles you flip in the overlay (Loupe, Rulers, Frame, Rounded, Snap, and others) are remembered.

## For developers

Xcode with a macOS 26 SDK and Swift 6.2 or later. One third-party package: [Sparkle](https://sparkle-project.org) 2.10.0 for updates, fetched by SwiftPM as a prebuilt binary and embedded in `Snug.app/Contents/Frameworks`.

```sh
SNUG_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" uv run scripts/build.py   # builds build/Snug.app, the lab app and build/ScreenshotBench
swift test --disable-sandbox    # unit tests
```

`scripts/build.py` signs Snug with the code signing identity in `SNUG_SIGNING_IDENTITY` (`security find-identity -v -p codesigning` lists yours) and stops if it is unset. A fixed identity keeps the Screen Recording permission across rebuilds. If you have a Developer ID Application identity, sign every build with it: macOS ties Snug's permissions to the signer, so a local build and a release build signed by different identities each take the other's permissions away. Every build runs under the hardened runtime.

A release build signs with a Developer ID Application identity, notarizes with the `snug-notary` keychain profile (`xcrun notarytool store-credentials snug-notary --apple-id APPLE_ID --team-id TEAMID`), staples the ticket and writes `build/release/Snug-VERSION.zip`, leaving `build/Snug.app` as it was:

```sh
SNUG_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" uv run scripts/build.py --release
```

### Releasing an update

Snug checks `appcast.xml` on the `main` branch for updates (`SUFeedURL`), and Sparkle installs only a zip signed with the EdDSA key whose public half is `SUPublicEDKey` in `scripts/build.py`. The private key is in the login keychain of the Mac that ran Sparkle's `generate_keys`. A release:

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `scripts/build.py`. Sparkle compares `CFBundleVersion`, so it must go up every release.
2. Run the release build above. After notarizing, it signs the zip with `sign_update` (the keychain may ask to allow access) and adds the release as the newest item in `appcast.xml`, with its download at `https://github.com/hedgertronic/snug/releases/download/vVERSION/Snug-VERSION.zip`.
3. Create the GitHub release `vVERSION` with `build/release/Snug-VERSION.zip` attached, then commit `appcast.xml` and push it to `main`. Publish the zip first: once the appcast is on `main`, running copies offer the update.

Back up the private key, since without it no installed copy accepts another update. Sparkle's tools are in `.build/artifacts/<checkout directory>/Sparkle/bin` after a build:

```sh
.build/artifacts/snug/Sparkle/bin/generate_keys -x snug-sparkle-key.txt   # export; store it in a password manager, then delete the file
.build/artifacts/snug/Sparkle/bin/generate_keys -f snug-sparkle-key.txt   # import on another Mac
```

Test fixtures are in `Tests/Fixtures` and `Tests/ScreenshotCoreTests/Fixtures`. The repo also holds the original detector lab (`ScreenshotLab`) and `ScreenshotBench`, the detector benchmark:

```sh
build/ScreenshotBench suite --manifest Tests/Fixtures/evaluation/public-suite.json --baseline Tests/Fixtures/evaluation/baselines/public-suite.json --output DIR
```

Run `build/ScreenshotBench` with no arguments for every subcommand.

## Support

Snug is free. If it saves you time, [buy me a bag of sunflower seeds](https://ko-fi.com/hedgertronic).

## License

MIT. See `LICENSE`.
