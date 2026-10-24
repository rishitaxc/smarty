#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${1:-release}"
swift build -c "$configuration" --product Side
app_path="$HOME/Applications/Side.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp ".build/$configuration/Side" "$app_path/Contents/MacOS/.Side.next"
mv -f "$app_path/Contents/MacOS/.Side.next" "$app_path/Contents/MacOS/Side"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Side</string>
<key>CFBundleIdentifier</key><string>dev.side.notch</string>
<key>CFBundleName</key><string>Side</string>
<key>CFBundleDisplayName</key><string>Side</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Side listens when you press Talk so Sol can answer and draw your question.</string>
<key>NSScreenCaptureUsageDescription</key><string>Side captures your selected display when you ask a question so Sol can explain and highlight what you see.</string>
</dict></plist>
PLIST
codesign --force --sign - --identifier dev.side.notch "$app_path"
print "Built $app_path"
