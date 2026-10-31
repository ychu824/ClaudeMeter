#!/usr/bin/env bash
# Builds TokenTide.app next to this script. Needs: xcode-select --install
#
#   ./build.sh                               native arch, ad-hoc signed (local use)
#   UNIVERSAL=1 ./build.sh                   arm64 + x86_64
#   SIGN_ID="Developer ID Application: …" ./build.sh
#                                            Developer ID + hardened runtime (for notarization)
#   VERSION=1.2.3 ./build.sh                 sets CFBundleShortVersionString
set -euo pipefail
cd "$(dirname "$0")"

NAME=TokenTide
APP="$NAME.app"
VERSION="${VERSION:-0.0.0-dev}"
BUILD_NUM="${BUILD_NUM:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
MIN_OS=13.0

rm -rf "$APP" .build
mkdir -p "$APP/Contents/MacOS" .build

compile() {   # $1 = arch
  swiftc -O -parse-as-library -target "$1-apple-macos$MIN_OS" \
    TokenTide.swift -o ".build/$NAME-$1"
}

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  compile arm64
  compile x86_64
  lipo -create ".build/$NAME-arm64" ".build/$NAME-x86_64" -output "$APP/Contents/MacOS/$NAME"
else
  compile "$(uname -m)"
  cp ".build/$NAME-$(uname -m)" "$APP/Contents/MacOS/$NAME"
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>               <string>$NAME</string>
  <key>CFBundleDisplayName</key>        <string>$NAME</string>
  <key>CFBundleIdentifier</key>         <string>io.github.ychu824.TokenTide</string>
  <key>CFBundleExecutable</key>         <string>$NAME</string>
  <key>CFBundlePackageType</key>        <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>$VERSION</string>
  <key>CFBundleVersion</key>            <string>$BUILD_NUM</string>
  <key>LSMinimumSystemVersion</key>     <string>$MIN_OS</string>
  <key>LSUIElement</key>                <true/>
  <key>NSHumanReadableCopyright</key>   <string>© 2026 Yucheng Hu. MIT License.</string>
</dict>
</plist>
EOF

if [[ -n "${SIGN_ID:-}" ]]; then
  echo "Signing with: $SIGN_ID"
  # Hardened runtime + secure timestamp are required for notarization.
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

rm -rf .build
echo "Built $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/$NAME"))"
echo "Run:  open $APP"
echo "Keep: mv $APP /Applications/   (then right-click the widget → Launch at Login)"
