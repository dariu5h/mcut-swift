#!/usr/bin/env bash
# Build Cmcut.xcframework from the mcut submodule.
#
# Slices: iOS device (arm64), iOS simulator (arm64+x86_64 fat), macOS (arm64).
# Uses native CMake iOS support (CMAKE_SYSTEM_NAME=iOS) — no third-party toolchain.
# Deployment targets: iOS 18, macOS 15 (see docs/plans/mcut-swift-plan.md §9).
#
# Known upstream-header quirk handled here without modifying external/mcut:
#   mcut.h #includes "platform.h" (bundled) and uses `bool` without <stdbool.h>
#   (it's only ever compiled as C++ upstream). We add an umbrella header Cmcut.h
#   that includes <stdbool.h> before mcut.h and point the module map at it.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
export PATH="/opt/homebrew/bin:$PATH"

IOS_MIN=18.0
MAC_MIN=15.0
OUT="$ROOT/out"

build_dylib() {  # builddir sysroot "archs" deploy system_name
  local builddir=$1 sysroot=$2 archs=$3 deploy=$4 sysname=${5:-}
  local extra=()
  [ -n "$sysname" ] && extra+=("-DCMAKE_SYSTEM_NAME=$sysname")
  cmake -B "$builddir" -S external/mcut "${extra[@]}" \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_ARCHITECTURES="$archs" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$deploy" \
    -DMCUT_BUILD_AS_SHARED_LIB=ON -DMCUT_BUILD_TESTS=OFF -DMCUT_BUILD_TUTORIALS=OFF \
    -DCMAKE_BUILD_TYPE=Release >/dev/null
  cmake --build "$builddir" --config Release >/dev/null
}

add_headers() {  # headers_dir
  cp external/mcut/include/mcut/mcut.h external/mcut/include/mcut/platform.h "$1/"
  printf '#include <stdbool.h>\n#include "mcut.h"\n' > "$1/Cmcut.h"
  printf 'framework module Cmcut { header "Cmcut.h" export * }\n' > "${1%/Headers}/Modules/module.modulemap"
}

write_plist() {  # file supported_platform minos_key minos_value
  cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>          <string>com.cutdigital.Cmcut</string>
  <key>CFBundleExecutable</key>          <string>Cmcut</string>
  <key>CFBundleName</key>                <string>Cmcut</string>
  <key>CFBundlePackageType</key>         <string>FMWK</string>
  <key>CFBundleVersion</key>             <string>1.3.0</string>
  <key>CFBundleShortVersionString</key>  <string>1.3.0</string>
  <key>CFBundleSupportedPlatforms</key>  <array><string>$2</string></array>
  <key>$3</key>                          <string>$4</string>
</dict>
</plist>
EOF
}

wrap_flat() {  # dylib framework_dir supported_platform minos   (iOS: flat layout)
  local dylib=$1 fw=$2
  rm -rf "$fw"; mkdir -p "$fw/Headers" "$fw/Modules"
  cp "$dylib" "$fw/Cmcut"
  install_name_tool -id "@rpath/Cmcut.framework/Cmcut" "$fw/Cmcut"
  add_headers "$fw/Headers"
  write_plist "$fw/Info.plist" "$3" MinimumOSVersion "$4"
}

wrap_versioned() {  # dylib framework_dir minos   (macOS: versioned layout)
  local dylib=$1 fw=$2
  rm -rf "$fw"; mkdir -p "$fw/Versions/A/Headers" "$fw/Versions/A/Modules" "$fw/Versions/A/Resources"
  cp "$dylib" "$fw/Versions/A/Cmcut"
  install_name_tool -id "@rpath/Cmcut.framework/Versions/A/Cmcut" "$fw/Versions/A/Cmcut"
  add_headers "$fw/Versions/A/Headers"
  write_plist "$fw/Versions/A/Resources/Info.plist" MacOSX LSMinimumSystemVersion "$3"
  ln -sfn A "$fw/Versions/Current"
  ln -sfn Versions/Current/Cmcut     "$fw/Cmcut"
  ln -sfn Versions/Current/Headers   "$fw/Headers"
  ln -sfn Versions/Current/Modules   "$fw/Modules"
  ln -sfn Versions/Current/Resources "$fw/Resources"
}

echo "==> 1/4 build slices"
build_dylib "$ROOT/build-ios"     iphoneos        "arm64"        "$IOS_MIN" iOS
build_dylib "$ROOT/build-sim"     iphonesimulator "arm64;x86_64" "$IOS_MIN" iOS
build_dylib "$ROOT/build-macos"   macosx          "arm64"        "$MAC_MIN"

echo "==> 2/4 wrap frameworks"
rm -rf "$OUT"
wrap_flat      "$ROOT/build-ios/bin/libmcut.dylib"   "$OUT/ios/Cmcut.framework"   iPhoneOS        "$IOS_MIN"
wrap_flat      "$ROOT/build-sim/bin/libmcut.dylib"   "$OUT/sim/Cmcut.framework"   iPhoneSimulator "$IOS_MIN"
wrap_versioned "$ROOT/build-macos/bin/libmcut.dylib" "$OUT/macos/Cmcut.framework" "$MAC_MIN"

echo "==> 3/4 create xcframework"
xcodebuild -create-xcframework \
  -framework "$OUT/ios/Cmcut.framework" \
  -framework "$OUT/sim/Cmcut.framework" \
  -framework "$OUT/macos/Cmcut.framework" \
  -output "$OUT/Cmcut.xcframework" >/dev/null

echo "==> 4/4 zip + checksum"
( cd "$OUT" && zip -qry Cmcut.xcframework.zip Cmcut.xcframework )
echo "    checksum: $(swift package compute-checksum "$OUT/Cmcut.xcframework.zip")"
echo "==> done: $OUT/Cmcut.xcframework"
