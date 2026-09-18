#!/usr/bin/env python3
"""Read-only validation of a local or downloaded Memos DMG. Never launches the app."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import subprocess
import tempfile


def checksum(dmg):
    entries = pathlib.Path(str(dmg) + '.sha256').read_text().strip().splitlines()
    if len(entries) != 1:
        raise ValueError('Expected one checksum entry')
    digest, filename = entries[0].split(maxsplit=1)
    if filename.lstrip('*') != dmg.name:
        raise ValueError('Checksum filename does not match DMG')
    actual = hashlib.sha256(dmg.read_bytes()).hexdigest()
    if digest != actual:
        raise ValueError('DMG SHA-256 mismatch')
    return actual


def provenance(info, commit, run_id=None):
    if (info.get('pr_head_sha') or info.get('build_sha')) != commit:
        raise ValueError('Artifact is from a different commit')
    if run_id is not None and str(info.get('run_id')) != str(run_id):
        raise ValueError('Artifact is from a different workflow run')


def verify(dmg, expected_commit=None, expected_run=None):
    dmg = pathlib.Path(dmg).resolve()
    digest = checksum(dmg)
    info_path = dmg.parent / 'BUILD_INFO.json'
    info = json.loads(info_path.read_text()) if info_path.exists() else None
    if expected_commit:
        if info is None:
            raise ValueError('BUILD_INFO.json is required for a CI artifact')
        provenance(info, expected_commit, expected_run)
    subprocess.run(['hdiutil', 'verify', str(dmg)], check=True, stdout=subprocess.DEVNULL)
    with tempfile.TemporaryDirectory(prefix='memos-dmg-check-') as mount:
        attached = False
        try:
            subprocess.run(['hdiutil', 'attach', str(dmg), '-readonly', '-nobrowse', '-mountpoint', mount],
                           check=True, stdout=subprocess.DEVNULL)
            attached = True
            app = pathlib.Path(mount) / 'Memos.app'
            subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
            with (app / 'Contents/Info.plist').open('rb') as handle:
                plist = plistlib.load(handle)
            if plist.get('CFBundleIdentifier') != 'app.memos.popup' or plist.get('LSMinimumSystemVersion') != '14.0':
                raise ValueError('Unexpected bundle identity or minimum macOS version')
            binary = app / 'Contents/MacOS/MemosPopup'
            architectures = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).strip().split()
            if set(architectures) != {'arm64', 'x86_64'}:
                raise ValueError(f'Expected Universal app, got {architectures}')
            if info and set(info.get('architectures', [])) != set(architectures):
                raise ValueError('Binary architectures do not match build provenance')
            applications = pathlib.Path(mount) / 'Applications'
            if not applications.is_symlink() or str(applications.readlink()) != '/Applications':
                raise ValueError('Missing Applications installation link')
            result = {'dmg': str(dmg), 'sha256': digest, 'architectures': architectures,
                      'version': plist['CFBundleShortVersionString'], 'build': plist['CFBundleVersion'],
                      'minimum_macos': plist['LSMinimumSystemVersion'], 'build_info': info,
                      'checks': ['checksum', 'image_integrity', 'signature', 'bundle', 'architectures', 'installation_link']}
        finally:
            if attached:
                subprocess.run(['hdiutil', 'detach', mount], check=True, stdout=subprocess.DEVNULL)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('dmg', type=pathlib.Path)
    parser.add_argument('--commit', help='Require matching BUILD_INFO.json provenance')
    parser.add_argument('--run', help='Require matching workflow run ID')
    parser.add_argument('--report', type=pathlib.Path)
    args = parser.parse_args()
    try:
        result = verify(args.dmg, args.commit, args.run)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Artifact verification failed: {error}\n')
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
