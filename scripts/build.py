"""Build and package the local macOS prototype. Snug embeds Sparkle, its one third-party dependency, for updates.

With --release, Snug is also timestamped, zipped, notarized with the snug-notary keychain profile, stapled and zipped again for
download as build/release/Snug-VERSION.zip, and that zip, signed with the Sparkle EdDSA key in the login keychain, becomes the newest
item in appcast.xml. SNUG_SIGNING_IDENTITY must then be the Developer ID Application identity.
"""
from email.utils import formatdate
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
# One universal binary for Apple silicon and Intel Macs.
command = ["swift", "build", "--disable-sandbox", "-c", "release", "--arch", "arm64", "--arch", "x86_64"]
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
# Local symbols only serve a debugger; without them each architecture's slice is about a third smaller.
subprocess.run(["strip", "-x", str(snug_contents / "MacOS/Snug")], check=True)
# A fresh copy of Sparkle.framework, its Versions symlinks kept, so nothing from an earlier Sparkle stays behind.
framework = snug_contents / "Frameworks/Sparkle.framework"
if framework.exists():
    shutil.rmtree(framework)
subprocess.run(["ditto", str(binary_dir / "Sparkle.framework"), str(framework)], check=True)
# actool compiles the Icon Composer icon into Assets.car, which macOS 26 draws in every icon style (default, dark, clear, tinted), and a
# Snug.icns for anything that reads CFBundleIconFile.
with tempfile.TemporaryDirectory() as scratch:
    subprocess.run(["xcrun", "actool", str(root / "brand/Snug.icon"), "--compile", str(snug_contents / "Resources"), "--platform", "macosx",
                    "--minimum-deployment-target", "26.0", "--app-icon", "Snug", "--output-partial-info-plist", str(Path(scratch) / "icon.plist")],
                   check=True, capture_output=True)
# macOS loads the fonts in ATSApplicationFontsPath for the app alone: the wordmark's Fredoka Bold and its license.
(snug_contents / "Resources/Fonts").mkdir(exist_ok=True)
for name in ("Fredoka-Bold.ttf", "OFL.txt"):
    shutil.copy2(root / "brand/fonts" / name, snug_contents / "Resources/Fonts" / name)
snug_info = {
    "CFBundleExecutable": "Snug",
    "CFBundleIdentifier": "com.hedgertronic.snug",
    "CFBundleName": "Snug",
    "CFBundleDisplayName": "Snug",
    "CFBundleIconFile": "Snug",
    "CFBundleIconName": "Snug",
    "ATSApplicationFontsPath": "Fonts",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "0.1.0",
    "CFBundleVersion": "1",
    "LSMinimumSystemVersion": "26.0",
    "LSUIElement": True,
    "NSPrincipalClass": "NSApplication",
    "NSHighResolutionCapable": True,
    "NSScreenCaptureUsageDescription": "Snug freezes the display under the pointer so you can choose what to copy.",
    "SUFeedURL": "https://raw.githubusercontent.com/hedgertronic/snug/main/appcast.xml",
    "SUPublicEDKey": "ZEuRf2celsTZdW8b4sBNlKNOXeqiNkawPIPmQE4mgWg=",
}
with (snug_contents / "Info.plist").open("wb") as stream:
    plistlib.dump(snug_info, stream)
# The hardened runtime is on in every build, so local builds run under the same rules as a notarized release. Signing goes inside out,
# as Sparkle's docs sign it: Sparkle's XPC services and helpers, then the framework, then the app.
codesign = ["codesign", "--force", "--options", "runtime", *(["--timestamp"] if release else []), "--sign", signing_identity]
sparkle = framework / "Versions/B"
subprocess.run([*codesign, str(sparkle / "XPCServices/Installer.xpc")], check=True)
subprocess.run([*codesign, "--preserve-metadata=entitlements", str(sparkle / "XPCServices/Downloader.xpc")], check=True)
subprocess.run([*codesign, str(sparkle / "Autoupdate")], check=True)
subprocess.run([*codesign, str(sparkle / "Updater.app")], check=True)
subprocess.run([*codesign, str(framework)], check=True)
subprocess.run([*codesign, str(snug)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(snug)], check=True)
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
    # Sparkle's tools come with its SwiftPM artifact. sign_update prints the zip's EdDSA signature and length as enclosure attributes.
    sign_update = root / ".build/artifacts" / root.name.lower() / "Sparkle/bin/sign_update"
    signature = subprocess.run([str(sign_update), str(archive)], check=True, text=True, capture_output=True).stdout.strip()
    version = snug_info["CFBundleShortVersionString"]
    appcast = root / "appcast.xml"
    if not appcast.exists():
        appcast.write_text('<?xml version="1.0" encoding="utf-8"?>\n'
                           '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
                           '    <channel>\n        <title>Snug</title>\n    </channel>\n</rss>\n')
    feed = appcast.read_text()
    # Sparkle compares CFBundleVersion, so each release needs a new one.
    if f"<sparkle:version>{snug_info['CFBundleVersion']}</sparkle:version>" in feed:
        sys.exit(f"appcast.xml already has CFBundleVersion {snug_info['CFBundleVersion']}; bump it and CFBundleShortVersionString")
    # The newest item comes first, right under the channel title.
    item = f"""
        <item>
            <title>{version}</title>
            <pubDate>{formatdate()}</pubDate>
            <sparkle:version>{snug_info['CFBundleVersion']}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>{snug_info['LSMinimumSystemVersion']}</sparkle:minimumSystemVersion>
            <enclosure url="https://github.com/hedgertronic/snug/releases/download/v{version}/{archive.name}" {signature} type="application/octet-stream"/>
        </item>"""
    appcast.write_text(feed.replace("<title>Snug</title>", "<title>Snug</title>" + item, 1))
    # Only the zip stays, so Spotlight and Launch Services find one Snug: build/Snug.app.
    shutil.rmtree(snug)
    print(f"Release: {archive}")
    print(f"Appcast: {appcast}")
print(f"Local app: {app}")
print(f"Snug: {archive if release else snug}")
print(f"Benchmark: {root / 'build/ScreenshotBench'}")
