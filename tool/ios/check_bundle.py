"""Verify the device build: client-only app, daemon package in the framework.

The app must carry the libcups CLIENT (FFI exports) and the on-device daemon
.deb, and must NOT carry the CUPS runtime as code — that only travels inside the
.deb, installed by the jailbreak package manager. Run on macOS after a device
build: python3 tool/ios/check_bundle.py <Runner.app>
"""
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

app = Path(sys.argv[1])
framework = app / 'Frameworks/printing_ffi.framework/printing_ffi'
assert framework.is_file(), f'Missing FFI framework: {framework}'
symbols = subprocess.check_output(['xcrun', 'nm', '-gU', str(framework)], text=True)
for symbol in ('get_printers', 'get_print_jobs', 'submit_raw_data_job',
               'printing_ffi_ios_select_server', 'printing_ffi_ios_configure_server',
               'printing_ffi_ios_configure_credentials',
               'printing_ffi_ios_probe'):
    assert any(line.endswith(' _' + symbol) for line in symbols.splitlines()), symbol

runtimes = list(app.rglob('CupsRuntime.bundle'))
assert not runtimes, f'CUPS runtime must not ship in the app, only in the .deb: {runtimes}'

debs = list(app.rglob('com.fotobox.cupsd.deb'))
assert debs == [framework.parent / 'com.fotobox.cupsd.deb'], \
    f'Expected the daemon .deb in the plugin framework (where the plugin looks): {debs}'
deb = debs[0]


def dpkg(*args):
    return subprocess.check_output(['dpkg-deb', *args, str(deb)], text=True)


fields = dict(line.split(': ', 1) for line in
              dpkg('--field').splitlines() if ': ' in line and not line.startswith(' '))
assert fields['Package'] == 'com.fotobox.cupsd', fields
assert fields['Architecture'] == 'iphoneos-arm64', fields
listing = dpkg('--contents')
prefix = './var/jb/usr/lib/fotobox-cups/'
for relative in (
    'bin/fotobox-cupsd', 'bin/libcupsd.so', 'bin/libcupsd_exec.so',
    'bin/libcupsbe_gutenprint53usb.so', 'bin/libcupsf_imagetoraster.so',
    'bin/libcupsf_rastertogutenprint.so', 'bin/libcupstool_gutenprint_genppd.so',
    'share/cups/mime/mime.types', 'share/cups/mime/imagetoraster.convs',
    'share/gutenprint/5.3/xml/printers/dyesub.xml',
):
    assert f' {prefix}{relative}\n' in listing + '\n', f'Missing from .deb: {relative}'
assert ' ./var/jb/Library/LaunchDaemons/com.fotobox.cupsd.plist' in listing

with tempfile.TemporaryDirectory() as root:
    subprocess.run(['dpkg-deb', '-x', str(deb), root], check=True)
    control = Path(root, 'control')
    subprocess.run(['dpkg-deb', '-e', str(deb), str(control)], check=True)
    for script in ('postinst', 'prerm', 'postrm'):
        assert (control / script).stat().st_mode & 0o111, f'{script} not executable'
    plist = plistlib.loads(Path(root, 'var/jb/Library/LaunchDaemons/com.fotobox.cupsd.plist').read_bytes())
    assert plist['UserName'] == 'mobile', plist
    bindir = Path(root, prefix, 'bin')
    for binary in sorted(bindir.iterdir()):
        assert binary.stat().st_mode & 0o111, f'Not executable: {binary.name}'
        subprocess.run(['xcrun', 'lipo', str(binary), '-verify_arch', 'arm64'], check=True)

    def entitlements(name):
        out = subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', str(bindir / name)],
                             check=True, capture_output=True).stdout
        return plistlib.loads(out) if out.strip() else {}

    daemon = entitlements('fotobox-cupsd')
    assert daemon.get('com.apple.private.security.no-sandbox') is True, daemon
    backend = entitlements('libcupsbe_gutenprint53usb.so')
    assert 'IOUSBHostDeviceUserClient' in backend.get('com.apple.security.iokit-user-client-class', []), backend

print('PASS: client-only app; daemon .deb in the framework with runtime, LaunchDaemon and entitlements')
