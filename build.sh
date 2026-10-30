#!/usr/bin/env bash
# Builds ClaudeMeter.app next to this script. Needs: xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

APP=ClaudeMeter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -parse-as-library ClaudeMeter.swift -o "$APP/Contents/MacOS/ClaudeMeter"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>             <string>ClaudeMeter</string>
  <key>CFBundleIdentifier</key>       <string>local.claudemeter</string>
  <key>CFBundleExecutable</key>       <string>ClaudeMeter</string>
  <key>CFBundlePackageType</key>      <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key>   <string>13.0</string>
  <key>LSUIElement</key>              <true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
echo "Run:    open $APP"
echo "Keep:   mv $APP /Applications/  (then right-click the widget → Launch at Login)"
