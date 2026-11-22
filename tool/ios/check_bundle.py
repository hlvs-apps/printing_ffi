"""Verify the device build really contains its printing code and payload."""
from pathlib import Path
import subprocess
import sys

app = Path(sys.argv[1])
framework = app / 'Frameworks/printing_ffi.framework/printing_ffi'
assert framework.is_file(), f'Missing FFI framework: {framework}'
symbols = subprocess.check_output(['xcrun', 'nm', '-gU', str(framework)], text=True)
for symbol in ('get_printers', 'get_print_jobs', 'start_cups_server',
               'printing_ffi_ios_select_server'):
    assert any(line.endswith(' _' + symbol) for line in symbols.splitlines()), symbol
bundles = list(app.rglob('CupsRuntime.bundle'))
assert len(bundles) == 1, f'Expected one CUPS payload, got {bundles}'
for relative in (
    'bin/libcupsd.so', 'bin/libcupsbe_gutenprint53usb.so',
    'bin/libcupsf_imagetoraster.so', 'bin/libcupsf_rastertogutenprint.so',
    'bin/libcupstool_gutenprint_genppd.so', 'bin/libcupscgi_admin.so',
    'share/cups/mime/imagetoraster.convs',
    'share/gutenprint/5.3/xml/printers/dyesub.xml',
):
    path = bundles[0] / relative
    assert path.is_file() and path.stat().st_size > 0, f'Missing payload: {path}'
    if relative.startswith('bin/'):
        subprocess.run(['xcrun', 'lipo', '-verify_arch', 'arm64', str(path)], check=True)
print('PASS: iOS FFI symbols and bundled CUPS/DNP runtime present')
