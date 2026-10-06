"""Build and package the local macOS prototype without third-party dependencies."""
from pathlib import Path
import os
import plistlib
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
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
subprocess.run([str(root / "build/ScreenshotBench"), "fixtures", str(root / "notes/fixtures")], check=True)
shutil.copy2(root / "notes/fixtures/grid-table.png", contents / "Resources/Demo.png")
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
print(f"Local app: {app}")
print(f"Benchmark: {root / 'build/ScreenshotBench'}")
