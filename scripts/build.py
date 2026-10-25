"""Build and package the local macOS prototype without third-party dependencies.

With --release, Snug is also timestamped, zipped, notarized with the snug-notary keychain profile, stapled and zipped again for
download as build/release/Snug-VERSION.zip. SNUG_SIGNING_IDENTITY must then be the Developer ID Application identity.
"""
from pathlib import Path
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
# A fixed identity, bundle ID, and path keep the Screen Recording grant across rebuilds.
signing_identity = os.environ["SNUG_SIGNING_IDENTITY"]
release = sys.argv[1:] == ["--release"]
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

# A release builds its own copy, so the everyday build/Snug.app keeps its signature and permissions.
snug = root / ("build/release/Snug.app" if release else "build/Snug.app")
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
    "CFBundleIdentifier": "com.hedgertronic.snug",
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
# The hardened runtime is on in every build, so local builds run under the same rules as a notarized release.
subprocess.run(["codesign", "--force", "--options", "runtime", *(["--timestamp"] if release else []), "--sign", signing_identity, str(snug)], check=True)
subprocess.run(["codesign", "--verify", "--strict", str(snug)], check=True)
if release:
    archive = root / f"build/release/Snug-{snug_info['CFBundleShortVersionString']}.zip"
    subprocess.run(["ditto", "-c", "-k", "--keepParent", str(snug), str(archive)], check=True)
    submitted = subprocess.run(["xcrun", "notarytool", "submit", str(archive), "--keychain-profile", "snug-notary", "--wait", "--output-format", "json"],
                               check=True, text=True, capture_output=True)
    submission = json.loads(submitted.stdout)
    if submission["status"] != "Accepted":
        subprocess.run(["xcrun", "notarytool", "log", submission["id"], "--keychain-profile", "snug-notary"], check=True)
        sys.exit(f"Notarization {submission['status']}: {submission['id']}")
    subprocess.run(["xcrun", "stapler", "staple", str(snug)], check=True)
    # The download holds the stapled app, so Gatekeeper accepts it offline.
    subprocess.run(["ditto", "-c", "-k", "--keepParent", str(snug), str(archive)], check=True)
    subprocess.run(["spctl", "--assess", "--type", "execute", "--verbose", str(snug)], check=True)
    # Only the zip stays, so Spotlight and Launch Services find one Snug: build/Snug.app.
    shutil.rmtree(snug)
    print(f"Release: {archive}")
print(f"Local app: {app}")
print(f"Snug: {archive if release else snug}")
print(f"Benchmark: {root / 'build/ScreenshotBench'}")
