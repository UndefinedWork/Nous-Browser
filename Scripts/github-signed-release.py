#!/usr/bin/env python3
"""Sign a staged Nous release. Each command runs in its own Actions step."""
import base64
from collections import deque
import hashlib
import html
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request
import xml.etree.ElementTree as ET
import zipfile


REPO = "UndefinedWork/Nous-Browser"
PUBLIC_KEY = "QCOwb6Q4i79beYb6aJziojzB00XbgP2auaR+BEComkY="
BASE = f"https://github.com/{REPO}/releases"
LATEST_FEED = BASE + "/latest/download/appcast.xml"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
VERSION = os.environ["RELEASE_VERSION"]
MODE = os.environ["RELEASE_MODE"]
TAG = "v" + VERSION
STEM = f"Nous-Browser-{VERSION}-macOS-arm64"
ZIP, DMG, SUMS, XML = STEM + ".zip", STEM + ".dmg", "SHA256SUMS.txt", "appcast.xml"
PAYLOADS = (ZIP, DMG, SUMS)
WORK = Path(os.environ["RUNNER_TEMP"]) / "nous-signed-release"
FEED_DIR = WORK / "feed"
PUBLIC_ZIP = f"{BASE}/download/{TAG}/{ZIP}"
ROOT = Path(__file__).resolve().parents[1]


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def version_number(value):
    require(re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", value),
            "Use a three-part numeric version, such as 1.4.22.")
    return tuple(map(int, value.split(".")))


def api(path, *args, output=None):
    command = ["gh", "api", *args, f"repos/{REPO}/{path}"]
    return subprocess.run(command, check=True, stdout=output or subprocess.PIPE).stdout


def metadata(path):
    return json.loads(api(path))


def source(path, commit):
    return api(f"contents/{path}?ref={commit}", "-H", "Accept: application/vnd.github.raw+json")


def release():
    # The CLI can resolve draft releases as well as public release tags.
    release_id = subprocess.check_output(["gh", "release", "view", TAG, "--repo", REPO,
                                          "--json", "databaseId", "--jq", ".databaseId"], text=True).strip()
    require(release_id.isdecimal(), "Could not resolve the staged GitHub release.")
    result = metadata("releases/" + release_id)
    require(result["tag_name"] == TAG, "Release tag changed.")
    return result


def assets(info):
    return {entry["name"]: entry for entry in info["assets"]}


def snapshot(info):
    table = assets(info)
    require(len(table) == len(info["assets"]), "Duplicate release asset names.")
    for name in PAYLOADS:
        require(name in table and table[name]["state"] == "uploaded"
                and re.fullmatch(r"sha256:[0-9a-f]{64}", table[name].get("digest") or ""),
                f"Missing, incomplete, or unverified release asset: {name}")
    return {name: [table[name][field] for field in ("id", "size", "digest")] for name in PAYLOADS}


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return "sha256:" + h.hexdigest()


def download(asset, path):
    with path.open("wb") as out:
        api(f"releases/assets/{asset['id']}", "-H", "Accept: application/octet-stream", output=out)
    require(path.stat().st_size == asset["size"] and digest(path) == asset["digest"],
            f"Downloaded bytes do not match GitHub's digest: {path.name}")


def check_commit():
    tip = os.environ["GITHUB_SHA"]
    require(re.fullmatch(r"[a-f0-9]{40}", tip), "Invalid workflow commit.")
    commit = metadata("commits/" + TAG)["sha"]
    compare = metadata(f"compare/{commit}...{tip}")
    require(compare["status"] in ("ahead", "identical") and compare["merge_base_commit"]["sha"] == commit,
            "The release tag must already exist on the main branch used by this run.")
    return commit


def check_order(info, build, current):
    stable = not info["draft"] and not info["prerelease"]
    if stable:
        require(current["id"] == info["id"], "Cannot replace or promote an older public release.")
    else:
        current_version = current["tag_name"].removeprefix("v")
        old_plist = plistlib.loads(source("Resources/Info.plist", current["tag_name"]))
        require(version_number(VERSION) > version_number(current_version)
                and int(build) > int(old_plist["CFBundleVersion"]),
                "The version and internal build number must both increase over the current stable release.")
    return stable


def english_notes(content):
    match = re.search(r"(?ims)^##[ \t]+English[ \t]*\r?$\n(.*?)(?=^##[ \t]+|\Z)", content)
    body = match.group(1) if match else re.sub(r"\A# Nous Browser [^\n]+\n", "", content)
    body = body.strip()
    require(body and not re.search(r"[\u3400-\u9fff]", body),
            "Add English release notes to Docs/releases/<version>.md in the release tag.")
    return body + "\n"


def inspect_zip(path):
    # Model internal symlinks before extraction, including chains and parent-relative links.
    links = {}
    with zipfile.ZipFile(path) as archive:
        members = archive.infolist()
        for entry in members:
            name = entry.filename.rstrip("/")
            parts = PurePosixPath(name).parts
            require(parts and parts[0] == "Nous Browser.app" and ".." not in parts
                    and chr(92) not in name, "Unexpected path in update ZIP.")
            if stat.S_ISLNK(entry.external_attr >> 16):
                target = PurePosixPath(archive.read(entry).decode())
                require(not target.is_absolute(), "External symlink in update ZIP.")
                links[parts] = target.parts
    for name in links:
        resolved = []
        remaining = deque(name)
        traversals = 0
        while remaining:
            part = remaining.popleft()
            if part == "..":
                require(len(resolved) > 1, "Symlink escapes the application bundle.")
                resolved.pop()
                continue
            resolved.append(part)
            target = links.get(tuple(resolved))
            if target is not None:
                traversals += 1
                require(traversals <= 40, "Symlink cycle in update ZIP.")
                resolved.pop()
                remaining.extendleft(reversed(target))


def validate_bundle(app, tagged):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    expected = {"CFBundleIdentifier": "com.cellier.nous-browser", "CFBundleExecutable": "NousBrowser",
                "CFBundleShortVersionString": VERSION, "NousDistributionChannel": "github",
                "SUPublicEDKey": PUBLIC_KEY, "SUFeedURL": LATEST_FEED,
                "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True}
    for field, value in expected.items():
        require(info.get(field) == value, f"Invalid packaged {field}.")
    for field in (*expected, "CFBundleVersion", "LSMinimumSystemVersion", "NousChromiumVersion", "NousStableStorageTeam"):
        require(field in tagged and info[field] == tagged[field], f"Package differs from tag: {field}.")
    require(re.fullmatch(r"[1-9][0-9]*", info["CFBundleVersion"]), "Invalid app build number.")
    require(re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", info["LSMinimumSystemVersion"]),
            "Invalid minimum macOS version.")
    for exe in ("NousBrowser", "NousBrowserMCP"):
        archs = subprocess.check_output(["/usr/bin/lipo", "-archs", app/"Contents/MacOS"/exe], text=True)
        require(archs.strip() == "arm64", f"Unexpected architecture in {exe}.")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app], check=True)
    signature = subprocess.check_output(["/usr/bin/codesign", "-dvvv", app], stderr=subprocess.STDOUT)
    cdhash = re.search(rb"(?m)^CDHash=([0-9a-f]+)$", signature)
    require(cdhash, "Could not read the bundle code signature.")
    return cdhash[1], b"Signature=adhoc" in signature.splitlines()


def prepare():
    WORK.mkdir(mode=0o700)
    FEED_DIR.mkdir()
    info = release()
    commit = check_commit()
    tagged = source("Resources/Info.plist", commit)
    plist = plistlib.loads(tagged)
    build = plist["CFBundleVersion"]
    latest = metadata("releases/latest")
    already_published = check_order(info, build, latest)
    snap = snapshot(info)
    (WORK/"tag.plist").write_bytes(tagged)
    notes_path = f"Docs/releases/{VERSION}.md"
    note_files = metadata(f"contents/Docs/releases?ref={commit}")
    if any(entry["path"] == notes_path for entry in note_files):
        notes = english_notes(source(notes_path, commit).decode())
    else:
        notes = english_notes(info.get("body") or "")
    for name in PAYLOADS:
        download(assets(info)[name], WORK/name)
    recorded = (WORK/SUMS).read_text().splitlines()
    require(sorted(recorded) == sorted(f"{snap[name][2][7:]}  {name}" for name in (ZIP, DMG)),
            "SHA256SUMS.txt must contain the two exact GitHub package digests.")
    inspect_zip(WORK/ZIP)
    extracted = WORK/"extracted"
    subprocess.run(["/usr/bin/ditto", "-x", "-k", WORK/ZIP, extracted], check=True)
    app = "Nous Browser.app"
    zipped_signature = validate_bundle(extracted/app, plist)
    if not already_published:
        prior_zip = f"Nous-Browser-{latest['tag_name'].removeprefix('v')}-macOS-arm64.zip"
        previous_asset = assets(latest).get(prior_zip)
        require(previous_asset, "Missing previous stable update archive for the macOS identity check.")
        previous = WORK/"previous-stable"
        previous.mkdir()
        download(previous_asset, previous/prior_zip)
        inspect_zip(previous/prior_zip)
        subprocess.run(["/usr/bin/ditto", "-x", "-k", previous/prior_zip, previous], check=True)
        subprocess.run(["/bin/zsh", ROOT/"Scripts/verify-release-identity.sh", extracted/app, previous/app],
                       check=True)
    mount = WORK/"mounted"
    mount.mkdir()
    subprocess.run(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, WORK/DMG],
                   check=True, stdout=subprocess.DEVNULL)
    try:
        require(validate_bundle(mount/app, plist) == zipped_signature, "DMG and ZIP contain different apps.")
    finally:
        subprocess.run(["/usr/bin/hdiutil", "detach", mount], check=True)
    notes += (f"\nRequires an Apple silicon Mac running macOS {plist['LSMinimumSystemVersion']} "
              "or later. Choose **Nous Browser → Check for Updates** to update, "
              "or download the DMG for a new installation.\n")
    _, is_ad_hoc = zipped_signature
    if is_ad_hoc:
        notes += ("\nThis build is ad hoc signed and has not been notarized by Apple. "
                  "If the previous app used a different signing identity, macOS may ask for "
                  "screen recording permission again.\n")
    (WORK/"notes.md").write_text(notes)
    os.link(WORK/ZIP, FEED_DIR/ZIP)
    (FEED_DIR/(STEM + ".html")).write_text("<pre>" + html.escape(notes) + "</pre>")
    state = {"id": info["id"], "commit": commit, "assets": snap, "build": build, "previous_id": latest["id"],
             "minimum": plist["LSMinimumSystemVersion"]}
    (WORK/"state.json").write_text(json.dumps(state))
    print(f"Verified tagged source and both packages for {VERSION} ({build}).", flush=True)


def state():
    return json.loads((WORK/"state.json").read_text())


def public_verify(feed):
    # The published client only has this public key. Exercise precisely that trust path.
    data = feed.read_bytes()
    marker = b"<!-- sparkle-signatures:\n"
    signed, sep, trailer = data.rpartition(marker)
    match = re.fullmatch(rb"edSignature: ([A-Za-z0-9+/=]+)\nlength: ([0-9]+)\n-->\s*", trailer)
    require(sep and match and int(match[2]) == len(signed), "Invalid signed appcast trailer.")
    require(b"<!DOCTYPE" not in signed and b"<!ENTITY" not in signed, "Invalid update XML.")
    items = ET.fromstring(signed).findall("./channel/item")
    require(len(items) == 1, "Expected one stable update in the feed.")
    item = items[0]
    expected = state()
    for field, value in {"version": expected["build"], "shortVersionString": VERSION,
                         "minimumSystemVersion": expected["minimum"], "hardwareRequirements": "arm64"}.items():
        require(item.findtext(SPARKLE + field) == value, f"Incorrect update {field}.")
    enc = item.find("enclosure")
    require(enc is not None and enc.get("url") == PUBLIC_ZIP
            and enc.get("length") == str(expected["assets"][ZIP][1]), "Wrong update URL or file size.")
    validations = [(signed, match[1].decode()), (None, enc.get(SPARKLE+"edSignature", ""))]
    # CryptoKit is part of the macOS SDK. No dependency downloaded from the release is executed.
    swift = WORK/"verify-public.swift"
    swift.write_text("""import CryptoKit
import Foundation
let args = CommandLine.arguments
guard let bytes = Data(base64Encoded: args[1]),
      let signature = Data(base64Encoded: args[2]) else { exit(1) }
let key = try Curve25519.Signing.PublicKey(rawRepresentation: bytes)
let content = try Data(contentsOf: URL(fileURLWithPath: args[3]), options: .mappedIfSafe)
exit(key.isValidSignature(signature, for: content) ? 0 : 1)
""")
    binary = WORK/"verify-public"
    if not binary.exists():
        subprocess.run(["xcrun", "swiftc", swift, "-o", binary], check=True)
    for content, signature in validations:
        path = WORK/ZIP
        if content is not None:
            path = WORK/"feed-content"
            path.write_bytes(content)
        subprocess.run([binary, PUBLIC_KEY, signature, path], check=True)
    print("Verified the update feed and archive using the installed clients' public key.")


def sign():
    secret = os.environ.pop("NOUS_ED25519_KEY", "").strip()
    require(len(base64.b64decode(secret, validate=True)) == 32, "Missing or invalid release signing secret.")
    tool = Path(os.environ["SPARKLE_BIN"]) / "generate_appcast"
    # Only the signing step receives the secret. Remove it from child environments.
    with tempfile.TemporaryDirectory(dir=os.environ["RUNNER_TEMP"]) as tmp:
        key = Path(tmp)/"key"
        key.touch(mode=0o600)
        key.write_text(secret + "\n")
        del secret
        subprocess.run(["xcrun", "swift", ROOT/"Scripts/verify-update-key.swift", key, WORK/"tag.plist"], check=True)
        subprocess.run([tool, "--ed-key-file", key, "--maximum-deltas", "0", "--embed-release-notes",
                        "--download-url-prefix", f"{BASE}/download/{TAG}/", FEED_DIR], check=True)
    public_verify(FEED_DIR/XML)


def recheck():
    expected = state()
    info = release()
    require(info["id"] == expected["id"] and snapshot(info) == expected["assets"]
            and check_commit() == expected["commit"], "The release or its assets changed. Start a new run.")
    latest = metadata("releases/latest")
    stable = check_order(info, expected["build"], latest)
    require(stable or latest["id"] == expected["previous_id"],
            "The stable release changed after the macOS identity check. Start a new run.")
    return info, stable


def publish():
    info, stable = recheck()
    if MODE == "verify":
        print("Verification run. The release is unchanged.")
        return
    table = assets(info)
    if XML in table:
        prior = WORK/"previous.xml"
        download(table[XML], prior)
        # Preserve a matching signed manifest across retries, including on public releases.
        try:
            public_verify(prior)
        except (SystemExit, ET.ParseError, subprocess.CalledProcessError):
            require(info["draft"], "The public release contains a different signed feed.")
            # Failed or interrupted earlier draft attempts can be repaired while still private.
            fresh, _ = recheck()
            require(fresh["draft"] and assets(fresh)[XML]["id"] == table[XML]["id"],
                    "The draft changed before replacing its previous feed.")
            manifest = FEED_DIR/XML
            subprocess.run(["gh", "release", "upload", TAG, manifest, "--repo", REPO, "--clobber"], check=True)
        else:
            manifest = prior
    else:
        require(not stable, "A published stable release is missing its signed feed.")
        manifest = FEED_DIR/XML
        subprocess.run(["gh", "release", "upload", TAG, manifest, "--repo", REPO], check=True)
    info, stable = recheck()
    require(assets(info)[XML]["digest"] == digest(manifest), "Remote feed changed before publication.")
    if not stable:
        subprocess.run(["gh", "release", "edit", TAG, "--repo", REPO, "--verify-tag",
                        "--title", f"Nous Browser {VERSION}", "--notes-file", WORK/"notes.md",
                        "--prerelease=false", "--draft=false", "--latest"], check=True)


def verify():
    info, stable = recheck()
    if not stable:
        require(MODE == "verify", "Release is not the public stable release.")
        public_verify(FEED_DIR/XML)
        print("Staged release verification passed.")
        return
    # Verify the same unauthenticated URLs used by installed applications, allowing CDN propagation.
    remote_feed = WORK/"public-appcast.xml"
    for attempt in range(8):
        try:
            with urllib.request.urlopen(LATEST_FEED, timeout=40) as f:
                remote_feed.write_bytes(f.read(2 * 1024 * 1024))
            if digest(remote_feed) == assets(info)[XML]["digest"]:
                break
        except OSError:
            pass
        if attempt == 7:
            raise SystemExit("The public latest feed has not updated. Rerun verification.")
        time.sleep(5)
    public_verify(remote_feed)
    with urllib.request.urlopen(PUBLIC_ZIP, timeout=120) as response:
        sha = hashlib.sha256()
        for chunk in iter(lambda: response.read(1024 * 1024), b""):
            sha.update(chunk)
    require("sha256:" + sha.hexdigest() == state()["assets"][ZIP][2], "Public ZIP digest mismatch.")
    print(f"Verified the public stable update: {TAG}.")


if __name__ == "__main__":
    require(os.environ["GITHUB_REPOSITORY"] == REPO, "Unexpected release repository.")
    version_number(VERSION)
    require(MODE in ("verify", "publish"), "Unknown release mode.")
    actions = {"prepare": prepare, "sign": sign, "publish": publish, "verify": verify}
    require(len(sys.argv) == 2 and sys.argv[1] in actions, "Expected prepare, sign, publish, or verify.")
    actions[sys.argv[1]]()
