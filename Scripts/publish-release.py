#!/usr/bin/env python3
"""Publish the packaged release in dist/ as a GitHub Release, without a login.

Run after `zsh Scripts/package-release.sh` and after the version tag is pushed:

    python3 -I Scripts/publish-release.py            # version from Resources/Info.plist
    python3 -I Scripts/publish-release.py 1.4.19     # or a given version
    python3 -I Scripts/publish-release.py --check    # only check the token and files

The GitHub token is read from $NOUS_GITHUB_TOKEN or from
~/.config/nous-release/github-token (owner-only file, set up once). Use a
fine-grained token limited to UndefinedWork/Nous-Browser with
"Contents: Read and write". The token is never printed or written anywhere.

The release body comes from Docs/releases/<version>.md (without its title
line). Uploads the DMG, ZIP, SHA256SUMS.txt and appcast.xml, marks the release
as latest, checks what GitHub serves against the local files, then removes
the published files from dist/.
"""

import hashlib
import json
import os
import plistlib
import stat
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPO = "UndefinedWork/Nous-Browser"
ROOT = Path(__file__).resolve().parent.parent
TOKEN_FILE = Path.home() / ".config" / "nous-release" / "github-token"


def fail(message):
    print(f"publish-release: {message}", file=sys.stderr)
    sys.exit(1)


def token():
    value = os.environ.get("NOUS_GITHUB_TOKEN", "").strip()
    if value:
        return value
    if not TOKEN_FILE.exists():
        fail(f"no token: create {TOKEN_FILE} (see the comment at the top of this script)")
    mode = stat.S_IMODE(TOKEN_FILE.stat().st_mode)
    if mode & 0o077:
        fail(f"{TOKEN_FILE} must be readable by you only: run chmod 600 on it")
    value = TOKEN_FILE.read_text().strip()
    if not value:
        fail(f"{TOKEN_FILE} is empty")
    return value


def request(method, url, auth, body=None, content_type="application/json", length=None):
    headers = {"Authorization": f"Bearer {auth}", "Accept": "application/vnd.github+json",
               "X-GitHub-Api-Version": "2022-11-28"}
    data = body
    if isinstance(body, (dict, list)):
        data = json.dumps(body).encode()
    if data is not None:
        headers["Content-Type"] = content_type
        if length is not None:
            headers["Content-Length"] = str(length)
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=600) as response:
            raw = response.read()
            return response.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")[:300]
        return error.code, {"error": detail}


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download_sha256(url):
    digest = hashlib.sha256()
    with urllib.request.urlopen(url, timeout=600) as response:
        for chunk in iter(lambda: response.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    check_only = "--check" in sys.argv
    if args:
        version = args[0]
    else:
        with open(ROOT / "Resources" / "Info.plist", "rb") as handle:
            version = plistlib.load(handle)["CFBundleShortVersionString"]
    tag = f"v{version}"
    dist = ROOT / "dist"
    files = [dist / f"Nous-Browser-{version}-macOS-arm64.dmg", dist / f"Nous-Browser-{version}-macOS-arm64.zip",
             dist / "SHA256SUMS.txt", dist / "appcast.xml"]
    notes_file = ROOT / "Docs" / "releases" / f"{version}.md"

    auth = token()
    status, user = request("GET", f"https://api.github.com/repos/{REPO}", auth)
    if status != 200:
        fail(f"the token cannot read {REPO} (HTTP {status}); check its repository access")
    if not (user or {}).get("permissions", {}).get("push", False):
        fail(f"the token cannot publish to {REPO}; give it Contents: Read and write")
    print(f"Token OK for {REPO}.")

    missing = [str(f.relative_to(ROOT)) for f in files + [notes_file] if not f.exists()]
    if check_only:
        print("Release files present." if not missing else "Not packaged yet: " + ", ".join(missing))
        return
    if missing:
        fail("missing " + ", ".join(missing) + " (run Scripts/package-release.sh first)")
    if f"<sparkle:shortVersionString>{version}<" not in (dist / "appcast.xml").read_text():
        fail(f"dist/appcast.xml does not announce {version}")

    status, _ = request("GET", f"https://api.github.com/repos/{REPO}/git/ref/tags/{tag}", auth)
    if status != 200:
        fail(f"tag {tag} is not on GitHub; push it first")

    lines = notes_file.read_text().splitlines()
    if lines and lines[0].startswith("# "):
        lines = lines[1:]
    body = "\n".join(lines).strip() + "\n"

    status, release = request("GET", f"https://api.github.com/repos/{REPO}/releases/tags/{tag}", auth)
    if status == 404:
        status, release = request("POST", f"https://api.github.com/repos/{REPO}/releases", auth,
                                  {"tag_name": tag, "name": f"Nous Browser {version}", "body": body,
                                   "draft": False, "prerelease": False, "make_latest": "true"})
        if status != 201:
            fail(f"could not create the release (HTTP {status}): {release}")
        print(f"Created {release['html_url']}")
    elif status == 200:
        print(f"Release {tag} exists; adding any missing files.")
    else:
        fail(f"could not look up the release (HTTP {status})")

    existing = {asset["name"] for asset in release.get("assets", [])}
    types = {".dmg": "application/x-apple-diskimage", ".zip": "application/zip",
             ".xml": "application/xml", ".txt": "text/plain"}
    for path in files:
        if path.name in existing:
            print(f"  {path.name}: already uploaded")
            continue
        size = path.stat().st_size
        with open(path, "rb") as handle:
            status, _ = request("POST",
                                f"https://uploads.github.com/repos/{REPO}/releases/{release['id']}/assets?name={path.name}",
                                auth, handle, types[path.suffix], size)
        if status != 201:
            fail(f"upload of {path.name} failed (HTTP {status})")
        print(f"  {path.name}: uploaded")

    # What GitHub now serves must match what was built here.
    status, latest = request("GET", f"https://api.github.com/repos/{REPO}/releases/latest", auth)
    if status != 200 or latest.get("tag_name") != tag:
        fail(f"GitHub's latest release is {latest.get('tag_name') if latest else '?'}, not {tag}")
    base = f"https://github.com/{REPO}/releases/download/{tag}"
    for path in files:
        if download_sha256(f"{base}/{path.name}") != sha256(path):
            fail(f"{path.name} on GitHub differs from the local file")
    print(f"Verified: {tag} is the latest release and all files match.")

    for path in files:
        path.unlink()
    print("Removed the published files from dist/.")
    print(release.get("html_url") or f"https://github.com/{REPO}/releases/tag/{tag}")


if __name__ == "__main__":
    main()
