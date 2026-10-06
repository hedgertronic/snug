# Smart Screenshot Lab

Latest checkpoint and next steps: [October 5 handoff](notes/handoff-2026-10-05.md).

Two local macOS screenshot-selection prototypes in one native app. Geometry finds visual boundaries and grid cells, supplemented by Apple OCR for text. Apple Vision finds document structures and uses geometry for grid cells and edge panels. Switch detectors while inspecting the same image, hover to preview a crop, and use the keyboard to correct the selection.

Requires Apple Silicon and macOS 26 or later. The project uses Apple's frameworks and has no third-party Swift package dependencies or bundled language-model weights. The app bundle is ad-hoc signed for local development; it is not a notarized distribution build.

**Run the app**

Open `build/Smart Screenshot Lab.app`. A bundled synthetic table provides an immediate demo. Use **Open Image** to compare your own screenshots, or **Capture Screen** for live capture. macOS may require Screen Recording permission for live capture; saved-image analysis needs no such permission. Capture and analysis stay on the Mac.

| Input | Action |
| --- | --- |
| Hover | Text under the pointer, cell interiors, or whole tables at grid lines/borders |
| Tab / Shift–Tab | Cycle alternatives |
| Up / Down | Expand / shrink |
| Space | Lock / unlock |
| F | Full image or display |
| W | Containing window when using live capture |
| Drag, then pause briefly | Preview a nearby boundary; release accepts the visible snap |
| Option–drag | Keep the exact rectangle |
| Tab / Shift–Tab after a drag | Cycle snap alternatives and the original rectangle |
| Arrow keys in manual mode | Move crop; Shift increases the step |
| Return or click | Copy selected crop |
| Command–S | Save PNG |
| Escape | Cancel |

The lab retains a saved image after copying so you can compare detectors. A live capture closes its overlay after a successful copy or save. Changing detector starts another analysis. OCR runs once per analysis; pointer movement uses cached regions. Text selections represent visible lines or blocks, not editable-field metadata. An analysis result cannot replace a manually locked crop.

Smart snap examines pixels near the dragged rectangle independently of the hover detector, so it can find boundaries absent from the original candidate list. Yellow shows your rough rectangle; a teal dashed outline previews the snap. If no supported boundary appears before release, the crop stays as drawn. This is local edge detection with no downloaded model; borderless or ambiguous objects can still require manual selection.

**Build and verify**

Xcode with a macOS 26+ SDK and Swift 6.2+ is required. Run from this directory:

```sh
uv run --no-project scripts/build.py
swift test --disable-sandbox
uv run --no-project scripts/compare.py 3
```

The build script writes the app and CLI into `build`. The comparison script generates six synthetic fixtures, runs each detector in a separate process for each image, and saves raw JSON, outlined previews, and crops in `notes/results`. It writes a summary to `notes/measurements.md`.

Apple Vision needs access to macOS image-buffer and ML services. A restrictive execution sandbox may fail with `Failed to create CVPixelBuffer`; run the benchmark normally from Terminal rather than interpreting that error as a detection result. The build script redirects compiler caches into `.build` and disables SwiftPM's nested manifest sandbox for compatibility with managed development environments.

Analyze one existing image:

```sh
build/ScreenshotBench analyze --image /absolute/path/image.png --output notes/custom --detector vision --repeat 3
```

Use `--detector geometry` to compare the geometry engine. Without a labeled fixture manifest, the CLI reports candidates and timing but no crop accuracy. Screenshots supplied for evaluation are written only to the explicit local output directory.

Inspect a smart-snap request using source-image pixel coordinates:

```sh
build/ScreenshotBench snap --image notes/real-web/form-test.png --rect 350,458,580,64 --output notes/custom-snap
```

The output contains suggestion bounds and a preview: green is the rough drag, pink is the first suggestion, and blue shows alternatives.

**Scope and evidence**

The [finalized spec](notes/v1-spec.md) defines the product goal. [Measurements](notes/measurements.md) cover the generated fixtures, and [prototype findings](notes/prototype-findings.md) distinguish verified behavior from follow-up work. Synthetic results are not evidence of reliable selection across arbitrary apps. Global shortcut customization, accessibility integration, drag handles, and broad cross-app validation remain outside this initial comparison build.
