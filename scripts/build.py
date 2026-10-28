"""Build and package Snug.app, which embeds Sparkle, its one third-party dependency, for updates. With --lab, also the developer lab app
(Smart Screenshot Lab), the ScreenshotBench benchmark and its generated fixtures.

With --release, Snug is also timestamped, zipped, notarized with the snug-notary keychain profile, stapled and zipped again for
download as build/release/Snug-VERSION.zip, and that zip, signed with the Sparkle EdDSA key in the login keychain, becomes the newest
item in appcast.xml. SNUG_SIGNING_IDENTITY must then be the Developer ID Application identity. Before anything is built, a release
checks that VERSION and BUILD are new to appcast.xml, that the notary profile, Sparkle's sign_update and the signing key are there,
and that the feed has one place for the new item. Upload the zip to the GitHub release before publishing the updated appcast.xml.
"""
from email.utils import formatdate
from pathlib import Path
import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

# Sparkle compares CFBundleVersion, so each release needs a BUILD greater than every one already in appcast.xml.
VERSION = "1.0.0"
BUILD = "2"
MINIMUM_SYSTEM = "26.0"
# Where installed copies look for updates.
FEED_URL = "https://snugshot.app/appcast.xml"
PUBLIC_ED_KEY = "ZEuRf2celsTZdW8b4sBNlKNOXeqiNkawPIPmQE4mgWg="
NOTARY_PROFILE = "snug-notary"
# The Homebrew cask, in a clone of github.com/hedgertronic/homebrew-tap next to this repository.
CASK = Path(__file__).resolve().parents[2] / "homebrew-tap/Casks/snug.rb"
# The newest item goes right after the channel's title, the one place this line appears.
FEED_ANCHOR = "<title>Snug</title>"
EMPTY_FEED = ('<?xml version="1.0" encoding="utf-8"?>\n'
              '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
              f'    <channel>\n        {FEED_ANCHOR}\n    </channel>\n</rss>\n')

root = Path(__file__).resolve().parents[1]


def parse_arguments(arguments: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build build/Snug.app, or with --release a notarized download and its appcast item.")
    parser.add_argument("--release", action="store_true", help="notarize, zip and add the new version to appcast.xml")
    parser.add_argument("--lab", action="store_true", help="also build the developer lab app, the benchmark and its fixtures")
    options = parser.parse_args(arguments)
    if options.release and options.lab:
        parser.error("a release builds Snug alone; build the lab separately")
    return options


def check_feed(feed: str, version: str, build: str) -> None:
    """Exits unless `feed` has exactly one FEED_ANCHOR and `build` is a whole number above every sparkle:version in it, with `version` new."""
    if feed.count(FEED_ANCHOR) != 1:
        sys.exit(f"appcast.xml must have exactly one {FEED_ANCHOR}, where the new item goes; it has {feed.count(FEED_ANCHOR)}")
    if not build.isdigit():
        sys.exit(f"BUILD must be a whole number, not {build!r}")
    builds = [int(found) for found in re.findall(r"<sparkle:version>\s*(\d+)\s*</sparkle:version>", feed)]
    if builds and int(build) <= max(builds):
        sys.exit(f"appcast.xml already has build {max(builds)}; BUILD {build} must be greater")
    if re.search(rf"<sparkle:shortVersionString>\s*{re.escape(version)}\s*</sparkle:shortVersionString>", feed):
        sys.exit(f"appcast.xml already has version {version}; bump VERSION")


def feed_item(version: str, build: str, archive_name: str, signature: str) -> str:
    return f"""
        <item>
            <title>{version}</title>
            <pubDate>{formatdate()}</pubDate>
            <sparkle:version>{build}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>{MINIMUM_SYSTEM}</sparkle:minimumSystemVersion>
            <enclosure url="https://github.com/hedgertronic/snug/releases/download/v{version}/{archive_name}" {signature} type="application/octet-stream"/>
        </item>"""


def read_feed(appcast: Path) -> str:
    """The appcast's text, or an empty channel when there is no appcast yet."""
    return appcast.read_text() if appcast.exists() else EMPTY_FEED


def write_feed(appcast: Path, feed: str, item: str) -> None:
    """Writes `feed` with `item` after its one FEED_ANCHOR, through a temporary file renamed over `appcast`, so a failure leaves the old feed."""
    if feed.count(FEED_ANCHOR) != 1:
        sys.exit(f"appcast.xml must have exactly one {FEED_ANCHOR}")
    updated = feed.replace(FEED_ANCHOR, FEED_ANCHOR + item, 1)
    with tempfile.NamedTemporaryFile("w", dir=appcast.parent, prefix=".appcast-", suffix=".xml", delete=False) as temporary:
        temporary.write(updated)
    os.replace(temporary.name, appcast)


def write_cask(cask: Path, version: str, archive: Path) -> None:
    """Sets the Homebrew cask's `version` and `sha256` lines to `version` and `archive`'s SHA-256, through a temporary file renamed
    over `cask`. Exits unless the cask has exactly one of each line."""
    text = cask.read_text()
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    text, versions = re.subn(r'^(\s*version )"[^"]*"$', rf'\g<1>"{version}"', text, flags=re.M)
    text, digests = re.subn(r'^(\s*sha256 )"[0-9a-f]*"$', rf'\g<1>"{digest}"', text, flags=re.M)
    if versions != 1 or digests != 1:
        sys.exit(f"{cask.name} must have exactly one version line and one sha256 line")
    with tempfile.NamedTemporaryFile("w", dir=cask.parent, prefix=".snug-", suffix=".rb", delete=False) as temporary:
        temporary.write(text)
    os.replace(temporary.name, cask)


def sparkle_tool(name: str) -> Path:
    """One of the tools in Sparkle's SwiftPM artifact, under the checkout's package identity. Exits when none is found, or when more
    than one artifact folder has it, since which one the build resolved is then unknown."""
    found = sorted((root / ".build/artifacts").glob(f"*/Sparkle/bin/{name}"))
    if not found:
        sys.exit(f"Sparkle's {name} is missing from .build/artifacts; run swift package resolve")
    if len(found) > 1:
        sys.exit(f"Sparkle's {name} is in more than one artifact folder: {', '.join(str(path) for path in found)}; remove the stale ones")
    return found[0]


def signing_identity_name(identities: str, signing_identity: str) -> str:
    """The name of the one identity in `security find-identity -v -p codesigning` output that `signing_identity` (a hash or a name)
    matches. Exits unless exactly one identity (by hash; one listed twice counts once) matches and it is a Developer ID Application one."""
    # Each line is `  1) HASH "Developer ID Application: Name (TEAM)"`.
    matches = {}
    for line in identities.splitlines():
        if '"' in line and signing_identity in line:
            matches[line.split()[1]] = line.split('"')[1]
    names = sorted(matches.values())
    if len(matches) != 1 or not names[0].startswith("Developer ID Application"):
        sys.exit(f"SNUG_SIGNING_IDENTITY must name exactly one valid Developer ID Application identity; it matches {names or 'none'}")
    return names[0]


def check_release_tools(signing_identity: str, env: dict[str, str]) -> None:
    """Exits unless the signing identity is a valid Developer ID Application identity, the notary profile works, and Sparkle's tools and
    the private key matching PUBLIC_ED_KEY are there. Runs before any build, so a missing credential costs no notarization wait."""
    for tool in (["xcrun", "--find", "notarytool"], ["xcrun", "--find", "stapler"], ["which", "spctl"]):
        if subprocess.run(tool, capture_output=True).returncode != 0:
            sys.exit(f"{tool[-1]} is missing")
    identities = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], check=True, text=True, capture_output=True).stdout
    signing_identity_name(identities, signing_identity)
    if subprocess.run(["xcrun", "notarytool", "history", "--keychain-profile", NOTARY_PROFILE], capture_output=True).returncode != 0:
        sys.exit(f"The notary keychain profile {NOTARY_PROFILE} is missing or rejected; see xcrun notarytool store-credentials")
    subprocess.run(["swift", "package", "resolve"], cwd=root, env=env, check=True)
    sparkle_tool("sign_update")
    public_key = subprocess.run([str(sparkle_tool("generate_keys")), "-p"], text=True, capture_output=True)
    if public_key.returncode != 0 or public_key.stdout.strip() != PUBLIC_ED_KEY:
        sys.exit("The login keychain has no Sparkle private key matching PUBLIC_ED_KEY")
    if not CASK.is_file():
        sys.exit(f"The Homebrew cask {CASK} is missing; clone github.com/hedgertronic/homebrew-tap next to this repository")


def install_binary(source: Path, destination: Path) -> None:
    # A fresh inode avoids stale macOS code-signing state after executable replacement.
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as temporary:
        staging = Path(temporary.name)
    shutil.copy2(source, staging)
    os.replace(staging, destination)


def build_lab(binary_dir: Path) -> None:
    """The developer lab app at build/Smart Screenshot Lab.app, ad-hoc signed, and the benchmark at build/ScreenshotBench with its fixtures."""
    app = root / "build/Smart Screenshot Lab.app"
    contents = app / "Contents"
    (contents / "MacOS").mkdir(parents=True, exist_ok=True)
    (contents / "Resources").mkdir(exist_ok=True)
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
        "LSMinimumSystemVersion": MINIMUM_SYSTEM,
        "NSPrincipalClass": "NSApplication",
        "NSHighResolutionCapable": True,
        "NSScreenCaptureUsageDescription": "Capture the chosen display to select and copy a screenshot region.",
    }
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump(info, stream)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
    subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)


def main() -> None:
    options = parse_arguments(sys.argv[1:])
    release = options.release
    # A fixed identity, bundle ID, and path keep the Screen Recording grant across rebuilds.
    signing_identity = os.environ.get("SNUG_SIGNING_IDENTITY") or sys.exit("Set SNUG_SIGNING_IDENTITY to a code-signing identity")
    env = os.environ.copy()
    env["CLANG_MODULE_CACHE_PATH"] = str(root / ".build/clang-cache")
    env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(root / ".build/swift-cache")
    appcast = root / "appcast.xml"
    if release:
        check_feed(read_feed(appcast), VERSION, BUILD)
        check_release_tools(signing_identity, env)
    # One universal binary for Apple silicon and Intel Macs.
    command = ["swift", "build", "--disable-sandbox", "-c", "release", "--arch", "arm64", "--arch", "x86_64", *([] if options.lab else ["--product", "Snug"])]
    subprocess.run(command, cwd=root, env=env, check=True)
    result = subprocess.run(command + ["--show-bin-path"], cwd=root, env=env, check=True, text=True, capture_output=True)
    binary_dir = Path(result.stdout.strip().splitlines()[-1])
    if options.lab:
        build_lab(binary_dir)

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
                        "--minimum-deployment-target", MINIMUM_SYSTEM, "--app-icon", "Snug", "--output-partial-info-plist", str(Path(scratch) / "icon.plist")],
                       check=True, capture_output=True)
    # macOS loads the fonts in ATSApplicationFontsPath for the app alone: the wordmark's Fredoka Bold and its license.
    (snug_contents / "Resources/Fonts").mkdir(exist_ok=True)
    for name in ("Fredoka-Bold.ttf", "OFL.txt"):
        shutil.copy2(root / "brand/fonts" / name, snug_contents / "Resources/Fonts" / name)
    # The license notices: Snug's own, Sparkle's (with the notices of the code it bundles) from its SwiftPM artifact, and the font's.
    licenses = snug_contents / "Resources/Licenses"
    licenses.mkdir(exist_ok=True)
    for source, name in ((root / "LICENSE", "Snug.txt"), (sparkle_tool("sign_update").parents[1] / "LICENSE", "Sparkle.txt"),
                         (root / "brand/fonts/OFL.txt", "Fredoka.txt")):
        shutil.copy2(source, licenses / name)
    snug_info = {
        "CFBundleExecutable": "Snug",
        "CFBundleIdentifier": "com.hedgertronic.snug",
        "CFBundleName": "Snug",
        "CFBundleDisplayName": "Snug",
        "CFBundleIconFile": "Snug",
        "CFBundleIconName": "Snug",
        "ATSApplicationFontsPath": "Fonts",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": VERSION,
        "CFBundleVersion": BUILD,
        "LSMinimumSystemVersion": MINIMUM_SYSTEM,
        "LSUIElement": True,
        "NSPrincipalClass": "NSApplication",
        "NSHighResolutionCapable": True,
        "NSScreenCaptureUsageDescription": "Snug freezes the display under the pointer so you can choose what to copy.",
        "SUFeedURL": FEED_URL,
        "SUPublicEDKey": PUBLIC_ED_KEY,
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
        archive = root / f"build/release/Snug-{VERSION}.zip"
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(snug), str(archive)], check=True)
        submitted = subprocess.run(["xcrun", "notarytool", "submit", str(archive), "--keychain-profile", NOTARY_PROFILE, "--wait", "--output-format", "json"],
                                   check=True, text=True, capture_output=True)
        submission = json.loads(submitted.stdout)
        if submission["status"] != "Accepted":
            subprocess.run(["xcrun", "notarytool", "log", submission["id"], "--keychain-profile", NOTARY_PROFILE], check=True)
            sys.exit(f"Notarization {submission['status']}: {submission['id']}")
        subprocess.run(["xcrun", "stapler", "staple", str(snug)], check=True)
        # The download holds the stapled app, so Gatekeeper accepts it offline.
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(snug), str(archive)], check=True)
        subprocess.run(["spctl", "--assess", "--type", "execute", "--verbose", str(snug)], check=True)
        # sign_update prints the zip's EdDSA signature and length as enclosure attributes.
        signature = subprocess.run([str(sparkle_tool("sign_update")), str(archive)], check=True, text=True, capture_output=True).stdout.strip()
        # Checked again in case appcast.xml changed during notarization.
        feed = read_feed(appcast)
        check_feed(feed, VERSION, BUILD)
        write_feed(appcast, feed, feed_item(VERSION, BUILD, archive.name, signature))
        write_cask(CASK, VERSION, archive)
        print(f"Cask: {CASK} (commit and push it in homebrew-tap)")
        # Only the zip stays, so Spotlight and Launch Services find one Snug: build/Snug.app.
        shutil.rmtree(snug)
        print(f"Release: {archive}")
        print(f"Appcast: {appcast}")
    print(f"Snug: {archive if release else snug}")
    if options.lab:
        print(f"Lab: {root / 'build/Smart Screenshot Lab.app'}")
        print(f"Benchmark: {root / 'build/ScreenshotBench'}")


if __name__ == "__main__":
    main()
