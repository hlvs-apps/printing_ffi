#!/usr/bin/env bash
# Xcode device build: all executable code and printer data live in the app.
# No preinstalled CUPS, system /var/jb prefix, or jailbreak brand dependency.
set -euo pipefail
TASK_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(cd "$TASK_DIR/../.." && pwd)"
if [[ $(uname -s) != Darwin ]]; then
  echo 'iOS runtime build requires macOS/Xcode (Linux can run the Dart and portable C tests).' >&2
  exit 2
fi
[[ ${PLATFORM_NAME:-iphoneos} == iphoneos ]] || { echo 'iOS CUPS device build only' >&2; exit 2; }
for tool in xcrun cmake make pkg-config python3 patch; do command -v "$tool" >/dev/null; done
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
MACSDK="$(xcrun --sdk macosx --show-sdk-path)"
IOS_MIN=${IPHONEOS_DEPLOYMENT_TARGET:-14.0}
STAGE="$PLUGIN/ios/.build/arm64"
RUNTIME="$PLUGIN/ios/Resources/CupsRuntime.bundle"
CACHE="${PRINTING_IOS_CACHE:-$HOME/Library/Caches/printing_ffi-ios}"
mkdir -p "$CACHE/downloads" "$STAGE" "$RUNTIME"
# Include build logic and SDK identity in the cache. Never reuse Android objects.
KEY=$( { cat "$0" "$TASK_DIR/patch_sources.py" "$TASK_DIR/helper.entitlements" "$PLUGIN/tool/android/cupsfilters/imagetoraster.convs"; printf '%s\n' "$SDK" "$IOS_MIN"; } | shasum -a 256 | cut -d' ' -f1)
if [[ -f "$STAGE/complete" && $(cat "$STAGE/complete") == "$KEY" && -f "$RUNTIME/bin/libcupsd.so" ]]; then exit 0; fi
BUILD="$CACHE/$KEY"
mkdir -p "$BUILD" "$BUILD/usb-headers"
export CC="$(xcrun --sdk iphoneos --find clang)"
export CXX="$(xcrun --sdk iphoneos --find clang++)"
export AR="$(xcrun --sdk iphoneos --find ar)"
export RANLIB="$(xcrun --sdk iphoneos --find ranlib)"
export CFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=$IOS_MIN -O2 -fPIC"
export CXXFLAGS="$CFLAGS"
# Some generated-header rules invoke CPP without CFLAGS (notably libpng).
export CPP="$CC -E -arch arm64 -isysroot $SDK -miphoneos-version-min=$IOS_MIN"
export CXXCPP="$CXX -E -arch arm64 -isysroot $SDK -miphoneos-version-min=$IOS_MIN"
export CPPFLAGS=""
export LDFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=$IOS_MIN"
export LIBS=""
export PKG_CONFIG_PATH=""
export PKG_CONFIG_LIBDIR="$STAGE/lib/pkgconfig"
JOBS=${PRINTING_IOS_JOBS:-4}
fetch() {
  local name=$1 url=$2 sha=$3 archive="$CACHE/downloads/${2##*/}"
  [[ -f $archive ]] || curl --fail --location --retry 3 "$url" -o "$archive"
  [[ $(shasum -a 256 "$archive" | cut -d' ' -f1) == "$sha" ]] || { echo "Checksum mismatch: $archive" >&2; exit 1; }
  if [[ ! -d $BUILD/$name ]]; then mkdir -p "$BUILD/$name"; tar xf "$archive" -C "$BUILD/$name" --strip-components=1; fi
}
fetch cups https://github.com/OpenPrinting/cups/releases/download/v2.4.19/cups-2.4.19-source.tar.gz 820984b12a67f98705785aae2dd1347fe0ac097828001d4583ff64574aed6389
fetch usb https://github.com/libusb/libusb/releases/download/v1.0.27/libusb-1.0.27.tar.bz2 ffaa41d741a8a3bee244ac8e54a72ea05bf2879663c098c82fc5757853441575
fetch jpeg https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.0.4/libjpeg-turbo-3.0.4.tar.gz 99130559e7d62e8d695f2c0eaeef912c5828d5b84a0537dcb24c9678c9d5b76b
fetch png https://download.sourceforge.net/libpng/libpng-1.6.44.tar.xz 60c4da1d5b7f0aa8d158da48e8f8afa9773c1c8baa5d21974df61f1886b8ce8e
fetch filters https://github.com/OpenPrinting/cups-filters/releases/download/1.28.17/cups-filters-1.28.17.tar.xz 270a3752a960368aa99d431fb5d34f4039b2ac943c576d840612d1d8185c9bb9
fetch gutenprint https://downloads.sourceforge.net/project/gimp-print/gutenprint-5.3/5.3.5/gutenprint-5.3.5.tar.xz f5a9f47de28530b1ae2069cfbc647a9a641baeeabe809bb0ef2b3ec5b9668d70
python3 "$TASK_DIR/patch_sources.py" "$BUILD"
# iOS SDK ships the IOKit linker stub, but not the USB C headers. Use Xcode's
# macOS IOKit declarations only; Foundation/system headers still come from iOS.
# libusb is linked ONLY into the separate Gutenprint helper, never Runner.
[[ -f "$MACSDK/System/Library/Frameworks/IOKit.framework/Headers/usb/IOUSBLib.h" ]]
ln -sfn "$MACSDK/System/Library/Frameworks/IOKit.framework/Headers" "$BUILD/usb-headers/IOKit"
(
  cd "$BUILD/usb"
  CPPFLAGS="-isystem $BUILD/usb-headers" ./configure --host=aarch64-apple-darwin --prefix="$STAGE" --disable-shared --enable-static
  make -j"$JOBS"
  make install
)
(
  cd "$BUILD/cups"
  ac_cv_func_mbr_uid_to_uuid=no \
  ac_cv_header_membership_h=no \
  ac_cv_func_notify_post=no \
  ac_cv_header_notify_h=no \
  ac_cv_header_sandbox_h=no \
  ac_cv_header_xpc_xpc_h=no \
  ac_cv_func_SCDynamicStoreCopyComputerName=no \
  ac_cv_header_CoreFoundation_CoreFoundation_h=no \
  ac_cv_header_ApplicationServices_ApplicationServices_h=no \
  ac_cv_header_Security_Authorization_h=no \
  ./configure --host=aarch64-apple-darwin --prefix=/cups --disable-shared --enable-static \
    --with-tls=no --with-dnssd=no --with-ondemand=no --disable-pam --disable-dbus --disable-acl \
    --disable-libusb --disable-gssapi --without-rcdir --with-components=all --with-docdir=/cups/share/doc/cups --datadir=/cups/share
  make -C cups -j"$JOBS" libcups.a libcupsimage.a
  make -C ppdc -j"$JOBS" libcupsppdc.a
  make -C scheduler -j"$JOBS" cupsd cups-exec cups-deviced cups-driverd
  make -C cgi-bin -j"$JOBS" all
  for directory in cups data doc templates locale; do
    make -C "$directory" install DSTROOT="$BUILD/cups-install"
  done
)
cp -R "$BUILD/cups-install/cups/include/." "$STAGE/include/"
cp "$BUILD/cups/cups/libcups.a" "$BUILD/cups/cups/libcupsimage.a" "$STAGE/lib/"
# Retain CUPS' actual configured transitive libraries (iconv, resolv, etc.).
# Relocate its include/library paths and use -l so Darwin libtool does not nest
# complete archives inside libcupsfilters.a.
python3 - "$BUILD/cups/cups-config" "$STAGE" <<'PYCONFIG'
from pathlib import Path
import re
import sys
p=Path(sys.argv[2])/'bin/cups-config'
p.parent.mkdir(exist_ok=True)
s=Path(sys.argv[1]).read_text()
for key, value in [('includedir', sys.argv[2]+'/include'), ('libdir', sys.argv[2]+'/lib')]:
    s=re.sub(r'^'+key+r'=.*$', key+'="'+value+'"', s, flags=re.M)
s=re.sub(r'libs="[^"\n]*";', 'libs="-L$libdir -lcups $LIBS";', s)
p.write_text(s); p.chmod(0o755)
PYCONFIG

cmake -S "$BUILD/jpeg" -B "$BUILD/jpeg-build" -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 -DCMAKE_OSX_SYSROOT="$SDK" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" -DCMAKE_INSTALL_PREFIX="$STAGE" \
  -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF -DWITH_TESTS=OFF
cmake --build "$BUILD/jpeg-build" --parallel "$JOBS"
cmake --install "$BUILD/jpeg-build"
(
  cd "$BUILD/png"
  ./configure --host=aarch64-apple-darwin --prefix="$STAGE" --disable-shared --enable-static
  make -j"$JOBS"; make install
)
# The iOS SDK supplies zlib but no pkg-config metadata. Keep pkg-config
# isolated from Homebrew while allowing the staged libpng dependency to resolve.
sdk_zlib_version=$(awk '/^#define ZLIB_VERSION / {gsub(/"/, "", $3); print $3}' "$SDK/usr/include/zlib.h")
[[ -n "$sdk_zlib_version" ]]
cat > "$STAGE/lib/pkgconfig/zlib.pc" <<PC
Name: zlib
Description: zlib from the selected iPhoneOS SDK
Version: $sdk_zlib_version
Libs: -lz
Cflags:
PC
(
  cd "$BUILD/filters"
  export CPPFLAGS="-I$STAGE/include"
  export LDFLAGS="$LDFLAGS -L$STAGE/lib"
  # These configure checks belong to unused PDF/font/driverless targets.
  export LCMS_CFLAGS=-DUNUSED_LCMS LCMS_LIBS=' ' FREETYPE_CFLAGS=-DUNUSED_FREETYPE FREETYPE_LIBS=' '
  export FONTCONFIG_CFLAGS=-DUNUSED_FONTCONFIG FONTCONFIG_LIBS=' ' LIBQPDF_CFLAGS=-DUNUSED_QPDF LIBQPDF_LIBS=' '
  export GLIB_CFLAGS=-DUNUSED_GLIB GLIB_LIBS=' ' GIO_CFLAGS=-DUNUSED_GIO GIO_LIBS=' ' GIO_UNIX_CFLAGS=-DUNUSED_GIO GIO_UNIX_LIBS=' '
  ./configure --host=aarch64-apple-darwin --with-cups-config="$STAGE/bin/cups-config" \
    --disable-shared --enable-static --enable-imagefilters --with-jpeg --with-png --without-tiff \
    --disable-poppler --disable-ghostscript --disable-mutool --disable-exif --disable-dbus --disable-avahi --disable-braille --with-pdftops=gs
  make -j"$JOBS" libcupsfilters.la imagetoraster
)
(
  cd "$BUILD/gutenprint"
  export LIBUSB_CFLAGS="-I$STAGE/include/libusb-1.0"
  export LIBUSB_LIBS="$STAGE/lib/libusb-1.0.a -framework IOKit -framework CoreFoundation -framework Security -lobjc"
  ./configure --host=aarch64-apple-darwin --prefix=/gutenprint --with-cups="$STAGE" \
    --with-cups-config="$STAGE/bin/cups-config" --disable-nls --disable-cups-ppds --disable-test \
    --disable-samples --disable-escputil --without-gimp2 --disable-libgutenprintui2 --without-readline \
    --without-doc --disable-shared --enable-static
  make -j"$JOBS"
)
mkdir -p "$RUNTIME/bin" "$RUNTIME/share/cups" "$RUNTIME/share/doc/cups" "$RUNTIME/share/gutenprint/5.3/xml" "$RUNTIME/licenses"
copybin() { cp "$1" "$RUNTIME/bin/$2"; chmod 755 "$RUNTIME/bin/$2"; }
copybin "$BUILD/cups/scheduler/cupsd" libcupsd.so
for name in cups-deviced cups-driverd cups-exec; do copybin "$BUILD/cups/scheduler/$name" "libcupsd_$name.so"; done
for name in admin printers jobs classes help; do copybin "$BUILD/cups/cgi-bin/$name.cgi" "libcupscgi_$name.so"; done
copybin "$BUILD/filters/imagetoraster" libcupsf_imagetoraster.so
copybin "$BUILD/gutenprint/src/cups/backend_gutenprint" libcupsbe_gutenprint53usb.so
copybin "$BUILD/gutenprint/src/cups/rastertogutenprint.5.3" libcupsf_rastertogutenprint.so
copybin "$BUILD/gutenprint/src/cups/commandtodyesub" libcupsf_commandtodyesub.so
copybin "$BUILD/gutenprint/src/cups/cups-genppd.5.3" libcupstool_gutenprint_genppd.so
cp -R "$BUILD/cups-install/cups/share/cups/." "$RUNTIME/share/cups/"
cp -R "$BUILD/cups-install/cups/share/doc/cups/." "$RUNTIME/share/doc/cups/"
cp -R "$BUILD/gutenprint/src/xml/." "$RUNTIME/share/gutenprint/5.3/xml/"
# Only runtime XML data; build products never enter the app as resources.
find "$RUNTIME/share/gutenprint/5.3/xml" -type f ! -name '*.xml' ! -name 'xml-stamp' -delete
cp "$PLUGIN/tool/android/cupsfilters/imagetoraster.convs" "$RUNTIME/share/cups/mime/"
for name in cups usb jpeg png filters gutenprint; do
  for license in COPYING LICENSE LICENSE.md LICENSE.txt; do
    [[ ! -f "$BUILD/$name/$license" ]] || cp "$BUILD/$name/$license" "$RUNTIME/licenses/$name-$license"
  done
done
# Ad-hoc signatures are replaced with the jailbreak's accepted signatures when
# installing. Keep privileged helper entitlements OUT of the Runner application.
for binary in "$RUNTIME/bin/"*; do
  xcrun lipo -verify_arch arm64 "$binary"
  if xcrun otool -L "$binary" | tail -n +2 | awk '{print $1}' | grep -Ev '^(/usr/lib/|/System/Library/)' ; then
    echo "Non-system dynamic dependency in $binary" >&2; exit 1
  fi
  codesign --force --sign - --entitlements "$TASK_DIR/helper.entitlements" "$binary"
done
printf '%s' "$KEY" > "$STAGE/complete"
