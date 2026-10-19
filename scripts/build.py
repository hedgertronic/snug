"""Build and package the local macOS prototype without third-party dependencies."""
from pathlib import Path
import os
import plistlib
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
# A fixed identity, bundle ID, and path keep the Screen Recording grant across rebuilds.
signing_identity = os.environ["SNUG_SIGNING_IDENTITY"]
env = os.environ.copy()
env["CLANG_MODULE_CACHE_PATH"] = str(root / ".build/clang-cache")
env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(root / ".build/swift-cache")
command = ["swift", "build", "--disable-sandbox", "-c", "release"]
subprocess.run(command, cwd=root, env=env, check=True)
result = subprocess.run(command + ["--show-bin-path"], cwd=root, env=env, check=True, text=True, capture_output=True)
binary_dir = Path(result.stdout.strip().splitlines()[-1])
app = root / "build/Smart Screenshot Lab.app"
contents = app / "Contents"
(contents / "MacOS").mkdir(parents=True, exist_ok=True)
(contents / "Resources").mkdir(exist_ok=True)
def install_binary(source: Path, destination: Path) -> None:
    # A fresh inode avoids stale macOS code-signing state after executable replacement.
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as temporary:
        staging = Path(temporary.name)
    shutil.copy2(source, staging)
    os.replace(staging, destination)

install_binary(binary_dir / "ScreenshotLab", contents / "MacOS/ScreenshotLab")
install_binary(binary_dir / "ScreenshotBench", root / "build/ScreenshotBench")
subprocess.run([str(root / "build/ScreenshotBench"), "fixtures", str(root / "build/fixtures")], check=True)
shutil.copy2(root / "build/fixtures/grid-table.png", contents / "Resources/Demo.png")
info = {
    "CFBundleExecutable": "ScreenshotLab",
    "CFBundleIdentifier": "local.smartscreenshot.lab",
    "CFBundleName": "Smart Screenshot Lab",
    "CFBundleDisplayName": "Smart Screenshot Lab",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "0.1.0",
    "CFBundleVersion": "1",
    "LSMinimumSystemVersion": "26.0",
    "NSPrincipalClass": "NSApplication",
    "NSHighResolutionCapable": True,
    "NSScreenCaptureUsageDescription": "Capture the chosen display to select and copy a screenshot region.",
}
with (contents / "Info.plist").open("wb") as stream:
    plistlib.dump(info, stream)
subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)

snug = root / "build/Snug.app"
snug_contents = snug / "Contents"
(snug_contents / "MacOS").mkdir(parents=True, exist_ok=True)
(snug_contents / "Resources").mkdir(exist_ok=True)
install_binary(binary_dir / "Snug", snug_contents / "MacOS/Snug")
# Every icon size is scaled down from the 1024 master.
master = root / "brand/snug-icon-plum-coral-1024.png"
with tempfile.TemporaryDirectory() as scratch:
    iconset = Path(scratch) / "Snug.iconset"
    iconset.mkdir()
    for points in (16, 32, 128, 256, 512):
        for factor in (1, 2):
            pixels = points * factor
            name = f"icon_{points}x{points}{'@2x' if factor == 2 else ''}.png"
            subprocess.run(["sips", "-z", str(pixels), str(pixels), str(master), "--out", str(iconset / name)],
                           check=True, capture_output=True)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(snug_contents / "Resources/Snug.icns")], check=True)
snug_info = {
    "CFBundleExecutable": "Snug",
    "CFBundleIdentifier": "local.snug",
    "CFBundleName": "Snug",
    "CFBundleDisplayName": "Snug",
    "CFBundleIconFile": "Snug",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "0.1.0",
    "CFBundleVersion": "1",
    "LSMinimumSystemVersion": "26.0",
    "LSUIElement": True,
    "NSPrincipalClass": "NSApplication",
    "NSHighResolutionCapable": True,
    "NSScreenCaptureUsageDescription": "Snug freezes the display under the pointer so you can choose what to copy.",
}
with (snug_contents / "Info.plist").open("wb") as stream:
    plistlib.dump(snug_info, stream)
subprocess.run(["codesign", "--force", "--sign", signing_identity, str(snug)], check=True)
subprocess.run(["codesign", "--verify", "--strict", str(snug)], check=True)
print(f"Local app: {app}")
print(f"Snug: {snug}")
print(f"Benchmark: {root / 'build/ScreenshotBench'}")
