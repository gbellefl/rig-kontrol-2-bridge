#!/bin/sh
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
app="$here/Rig Kontrol 2 Bridge.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.rigkontrol2.midi-bridge</string>
<key>CFBundleName</key><string>Rig Kontrol 2 Bridge</string>
<key>CFBundleExecutable</key><string>RigKontrolBridge</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>6</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xcrun clang -Wall -Wextra -Werror -fobjc-arc -arch arm64 -mmacosx-version-min=13.0 \
    "$here/bridge.m" -framework Cocoa -framework IOKit -framework IOUSBHost \
    -framework CoreMIDI -o "$app/Contents/MacOS/RigKontrolBridge"
cp "$here/LICENSE" "$here/AppIcon.icns" "$app/Contents/Resources/"
codesign --force --options runtime --sign - "$app"
codesign --verify --deep --strict "$app"
