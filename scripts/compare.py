"""Run isolated detector processes on the fixture corpus and summarize results."""
from pathlib import Path
import json
import statistics
import subprocess
import sys
import os

root = Path(__file__).resolve().parents[1]
binary = Path(os.environ.get("SCREENSHOT_BENCH", str(root / "build/ScreenshotBench")))
fixtures = root / "notes/fixtures"
results = root / "notes/results"
repetitions = sys.argv[1] if len(sys.argv) > 1 else "3"
subprocess.run([str(binary), "fixtures", str(fixtures)], check=True)
manifest = json.loads((fixtures / "manifest.json").read_text())
results.mkdir(parents=True, exist_ok=True)
rows = []
for fixture in manifest:
    for detector in ("geometry", "vision"):
        result = subprocess.run([
            str(binary), "analyze", "--image", str(fixtures / fixture["file"]),
            "--output", str(results), "--detector", detector,
            "--repeat", repetitions, "--manifest", str(fixtures / "manifest.json"),
        ], timeout=90, text=True, capture_output=True)
        print(result.stdout.strip() or result.stderr[-1200:], flush=True)
        path = results / f"{Path(fixture['file']).stem}-{detector}.json"
        if result.returncode != 0 or not path.exists():
            rows.append(f"| {fixture['description']} | {detector} | failed | — | — | — | — | — |")
            continue
        data = json.loads(path.read_text())
        samples = data["samplesMilliseconds"]
        latency = f"{statistics.median(samples):.1f}" if samples else "failed"
        selected = f"{data.get('defaultIoU', 0):.2f}"
        best = f"{data.get('bestCandidateIoU', 0):.2f}"
        corrections = data.get("minimumKeyboardCorrectionsWithinTwo", "not within 2")
        rows.append(f"| {fixture['description']} | {detector} | {latency} | {data['peakProcessRSSBytes'] / 2**20:.0f} | {data['candidateCount']} | {selected} | {best} | {corrections} |")
report = """# Prototype measurements

Synthetic fixtures on the local Mac. Each detector/image combination runs in a separate process. Latency includes detector processing, with the first sample cold within that process and subsequent samples warm. Process RSS is a high-water mark for the benchmark process; system ML service memory is not included. These are exploratory measurements, not the 60-task product acceptance evaluation.

Green preview outline is the labeled target, pink is the default selection, and blue outlines show candidate proposals. IoU is intersection over union with the labeled rectangle; it does not itself prove that a crop contains all required content. The raw JSON also records the stricter edge tolerance check.

Keyboard corrections count Tab, Shift–Tab, Up, or Down from the default selection, with acceptance requiring every edge within 8 pixels of the labeled target. "Not within 2" includes absent targets and crops with different margins.

| Fixture | Detector | Median ms | Peak RSS MiB | Candidates | Default IoU | Best IoU | Corrections |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
""" + "\n".join(rows) + "\n"
(root / "notes/measurements.md").write_text(report)
print(f"Report: {root / 'notes/measurements.md'}")
