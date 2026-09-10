#!/usr/bin/env python3
"""Build the exact Xcode product, verify Release hygiene, install and launch it."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent

def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def release_gate(app, executable):
    markers = [b'FeedbackStore', b'FeedbackPanel', b'FeedbackRecord', b'swiftui-dev-feedback',
               b'connection.', b'Pick UI for Feedback', b'Feedback History', b'Save & pick next', b'FeedbackOverlay']
    data = executable.read_bytes()
    found = [m.decode() for m in markers if m in data]
    artifacts = [str(p.relative_to(app)) for p in app.rglob('*') if 'DevFeedback' in p.name]
    if found or artifacts:
        raise RuntimeError(f'Release contamination: {found + artifacts}')
    print('Release feedback exclusion: passed', flush=True)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--configuration', choices=['Debug', 'Release'], default='Release')
    parser.add_argument('--build-only', action='store_true')
    parser.add_argument('--no-launch', action='store_true')
    args = parser.parse_args()
    run(['xcodegen', 'generate'], cwd=ROOT)
    build_args = ['xcodebuild', '-project', ROOT / 'ConnectAndroid.xcodeproj', '-scheme', 'ConnectAndroid',
                  '-configuration', args.configuration, '-destination', 'platform=macOS',
                  '-derivedDataPath', ROOT / '.build/xcode']
    run(build_args + ['build'], cwd=ROOT)
    settings = json.loads(run(build_args + ['-showBuildSettings', '-json'], cwd=ROOT, capture_output=True, text=True).stdout)
    setting = next(item['buildSettings'] for item in settings if item['target'] == 'ConnectAndroid')
    app = Path(setting.get('TARGET_BUILD_DIR') or setting['BUILT_PRODUCTS_DIR']) / setting['FULL_PRODUCT_NAME']
    # EXECUTABLE_PATH is product-relative (App.app/Contents/MacOS/name).
    executable = app.parent / setting['EXECUTABLE_PATH']
    if not app.is_dir() or not executable.is_file():
        raise RuntimeError(f'Current build product missing: {app}')
    print(f'Built product: {app}', flush=True)
    if args.configuration == 'Release':
        if 'DEBUG' in setting.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '').split():
            raise RuntimeError('DEBUG is enabled in Release')
        release_gate(app, executable)
    run(['codesign', '--verify', '--deep', '--strict', app])
    if args.build_only:
        return
    destination = Path('/Applications') / app.name
    if destination.exists():
        plist = destination / 'Contents/Info.plist'
        import plistlib
        with plist.open('rb') as f:
            identity = plistlib.load(f).get('CFBundleIdentifier')
        if identity != setting['PRODUCT_BUNDLE_IDENTIFIER']:
            raise RuntimeError(f'Refusing to replace unrelated application {destination}')
    # Quit only this installed app before replacing its complete bundle.
    subprocess.run(['osascript', '-e', 'tell application id "com.monroestone.connectandroid" to quit'], capture_output=True)
    time.sleep(0.5)
    if destination.exists():
        shutil.rmtree(destination)
    run(['ditto', app, destination])
    installed_executable = destination / executable.relative_to(app)
    if sha(executable) != sha(installed_executable):
        raise RuntimeError('Installed executable hash differs from current build')
    run(['codesign', '--verify', '--deep', '--strict', destination])
    print(f'Installed: {destination}\nSHA-256 match: {sha(executable)}', flush=True)
    shortcut = Path.home() / 'Desktop' / app.name
    if not shortcut.exists() and not shortcut.is_symlink():
        shortcut.symlink_to(destination)
    elif shortcut.is_symlink() and shortcut.resolve() == destination:
        pass
    else:
        raise RuntimeError(f'App installed, but refusing to replace unrelated Desktop item: {shortcut}')
    print(f'Desktop shortcut: {shortcut}', flush=True)
    if not args.no_launch:
        run(['open', destination])
        time.sleep(2)
        processes = run(['ps', '-axo', 'pid=,command='], capture_output=True, text=True).stdout
        matching = [line for line in processes.splitlines() if line.strip().split(maxsplit=1)[-1].startswith(str(installed_executable))]
        if not matching:
            raise RuntimeError('Installed app launch could not be verified')
        print('Running installed process: ' + '\n'.join(matching), flush=True)

if __name__ == '__main__':
    main()
