"""Writes Snug's sounds to sounds/*.caf: soft sine plucks, quieter and shorter than the macOS shutter.

capture: one pluck when a capture lands on the pasteboard or disk.
record-start, record-stop: a rising and a falling pair of plucks.
"""
import math
import struct
import subprocess
import tempfile
import wave
from pathlib import Path

RATE = 44100
PEAK = 0.3


def pluck(frequency: float, seconds: float, decay: float) -> list[float]:
    """A sine with a quieter octave, a 3 ms attack and an exponential decay."""
    samples = []
    for index in range(int(RATE * seconds)):
        time = index / RATE
        envelope = min(1, time / 0.003) * math.exp(-time / decay)
        tone = math.sin(2 * math.pi * frequency * time) + 0.25 * math.sin(4 * math.pi * frequency * time)
        samples.append(envelope * tone / 1.25)
    return samples


def sequence(*notes: tuple[float, float]) -> list[float]:
    """Plucks `notes` (frequency, start in seconds) mixed into one buffer."""
    plucks = [(pluck(frequency, 0.16, 0.035), start) for frequency, start in notes]
    out = [0.0] * max(int(RATE * start) + len(samples) for samples, start in plucks)
    for samples, start in plucks:
        offset = int(RATE * start)
        for index, sample in enumerate(samples):
            out[offset + index] += sample
    return out


sounds = {
    "capture": sequence((1568, 0)),
    "record-start": sequence((1047, 0), (1568, 0.07)),
    "record-stop": sequence((1568, 0), (1047, 0.07)),
}
folder = Path(__file__).resolve().parent.parent / "sounds"
folder.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory() as scratch:
    for name, samples in sounds.items():
        loudest = max(abs(sample) for sample in samples)
        source = Path(scratch) / f"{name}.wav"
        with wave.open(str(source), "wb") as stream:
            stream.setnchannels(1)
            stream.setsampwidth(2)
            stream.setframerate(RATE)
            stream.writeframes(b"".join(struct.pack("<h", round(sample / loudest * PEAK * 32767)) for sample in samples))
        subprocess.run(["afconvert", "-f", "caff", "-d", "LEI16", str(source), str(folder / f"{name}.caf")], check=True)
        print(f"{name}.caf: {len(samples) / RATE * 1000:.0f} ms")
