#!/bin/sh
# Builds FloatingClock.app (universal: Apple silicon + Intel) from FloatingClock.swift.
# Usage:  sh build.sh
set -e

APP_NAME="FloatingClock"
DISPLAY_NAME="Floating Clock"
BUNDLE_ID="com.pcf0.FloatingClock"
VERSION="1.0"

cd "$(dirname "$0")"
APP="$APP_NAME.app"

echo "Compiling..."
swiftc -O -target arm64-apple-macos12  "$APP_NAME.swift" -o "$APP_NAME-arm64"
swiftc -O -target x86_64-apple-macos12 "$APP_NAME.swift" -o "$APP_NAME-x86"

echo "Creating $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$APP_NAME-arm64" "$APP_NAME-x86" -output "$APP/Contents/MacOS/$APP_NAME"
rm "$APP_NAME-arm64" "$APP_NAME-x86"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>          <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>          <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>                <string>$DISPLAY_NAME</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>$VERSION</string>
    <key>CFBundleVersion</key>             <string>1</string>
    <key>LSMinimumSystemVersion</key>      <string>12.0</string>
    <key>LSUIElement</key>                 <true/>
    <key>NSHighResolutionCapable</key>     <true/>
</dict>
</plist>
EOF

# Ad-hoc signature (Apple silicon won't run unsigned code)
codesign --force --sign - "$APP"

echo "Done: $(pwd)/$APP"
echo "Move it to /Applications before using Launch at Login."
