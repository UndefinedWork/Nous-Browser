#!/usr/bin/env python3
"""Inspect a Chromium-only release without launching it or accessing credentials."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parent.parent
ROLES = ('', ' (Alerts)', ' (GPU)', ' (Renderer)', ' (Aperitif)', ' (Aperitif Alerts)', ' (Aperitif GPU)', ' (Aperitif Renderer)')

def require(value, message):
    if not value:
        raise ValueError(message)

def run(*args):
    r = subprocess.run([str(x) for x in args], capture_output=True, text=True)
    require(r.returncode == 0, f'{args[0]}: {r.stderr.strip()}')
    return r.stdout

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for data in iter(lambda: f.read(1024 * 1024), b''):
            h.update(data)
    return h.hexdigest()

def inventory(app):
    result = {}
    for p in sorted(app.rglob('*')):
        rel = str(p.relative_to(app))
        if p.is_symlink():
            require(p.resolve().is_relative_to(app.resolve()), f'External symlink: {rel}')
            result[rel] = {'link': str(p.readlink())}
        elif p.is_file():
            require(not (p.stat().st_mode & 0o002), f'World-writable file: {rel}')
            result[rel] = {'sha256': digest(p), 'executable': bool(p.stat().st_mode & 0o111)}
    return result

def validate(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    source = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
    for key in ('CFBundleIdentifier', 'CFBundleExecutable', 'CFBundleVersion', 'CFBundleShortVersionString',
                'NousDistributionChannel', 'NousCredentialStorage', 'NousChromiumVersion',
                'SUFeedURL', 'SUPublicEDKey', 'SURequireSignedFeed', 'SUVerifyUpdateBeforeExtraction'):
        require(info.get(key) == source.get(key) and info.get(key) is not None, f'Metadata mismatch: {key}')
    require(info['CFBundleIdentifier'] == 'com.cellier.nous-browser' and info['NousDistributionChannel'] == 'github', 'Invalid distribution identity')
    require(info['NousCredentialStorage'] == 'local-key', 'Missing explicit no-prompt storage policy')
    require('NousSupportsEngineSwitching' not in info, 'Unexpected engine switch setting')
    for key in ('NSCameraUsageDescription','NSMicrophoneUsageDescription','NSBluetoothAlwaysUsageDescription'):
        require(isinstance(info.get(key), str) and info[key].strip(), f'Missing privacy description: {key}')
    mac = app / 'Contents/MacOS'
    require({p.name for p in mac.iterdir()} == {'NousBrowser','NousBrowserMCP'}, 'Unexpected top-level executable (WebKit/relaunch must not ship)')
    for p in mac.iterdir():
        require(run('/usr/bin/lipo', '-archs', p).strip() == 'arm64', f'Unexpected architecture: {p.name}')
        require('WebKit.framework' not in run('/usr/bin/otool', '-L', p), f'WebKit linked: {p.name}')
    framework = app / 'Contents/Frameworks'
    for name in ('NousCore.framework', 'Sparkle.framework'):
        require((framework / name).is_dir(), f'Missing framework: {name}')
    require(not (framework / 'Chromium Embedded Framework.framework').exists(), 'CEF must not ship')
    helpers = sorted((framework / 'NousCore.framework/Versions/Current/Helpers').glob('*.app'))
    require({h.name for h in helpers} == {'Chromium Helper'+role+'.app' for role in ROLES}, 'Missing/unexpected Chromium helper')
    for helper in helpers:
        h = plistlib.loads((helper/'Contents/Info.plist').read_bytes())
        require(h['CFBundleIdentifier'].startswith(info['CFBundleIdentifier']+'.helper'), 'Helper identity mismatch')
        require(h.get('CFBundleShortVersionString') == info['NousChromiumVersion'], 'Helper engine version mismatch')
        require(h.get('LSUIElement') in (True, '1'), 'Helper should not register as a user app')
        require('CFBundleURLTypes' not in h and 'CFBundleDocumentTypes' not in h, 'Helper registered as a document handler')
    require((app/'Contents/Resources/ThirdPartyNotices.txt').stat().st_size > 0, 'Missing attribution: ThirdPartyNotices.txt')
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', app)
    data = inventory(app)
    return {'version':info['CFBundleShortVersionString'], 'build':info['CFBundleVersion'],
            'engine':info['NousChromiumVersion'], 'files':data}

if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('app', type=Path)
    p.add_argument('--reference', type=Path)
    p.add_argument('--report', type=Path)
    a=p.parse_args()
    result=validate(a.app)
    if a.reference:
        require(result == validate(a.reference), 'Packaged app differs from verified source bundle')
    if a.report:
        a.report.write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
    print(f"Verified Chromium-only {result['version']} ({result['build']}): {len(result['files'])} file/link records")
