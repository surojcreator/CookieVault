#!/bin/bash
# CookieVault — Rebuild & Reinstall script
# Builds the app, packages the .app bundle with icon, codesigns ad-hoc, and installs to /Applications

set -e
PROJ_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "🔨 Building CookieVault..."
cd "$PROJ_DIR"
swift build -c release

echo "📦 Packaging .app bundle..."
APP="$PROJ_DIR/CookieVault.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/out/Products/Release/CookieVault" "$APP/Contents/MacOS/CookieVault"
chmod +x "$APP/Contents/MacOS/CookieVault"

cat > "$APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>CookieVault</string>
    <key>CFBundleIdentifier</key><string>com.cookievault.app</string>
    <key>CFBundleName</key><string>CookieVault</string>
    <key>CFBundleDisplayName</key><string>CookieVault</string>
    <key>CFBundleVersion</key><string>1.2</string>
    <key>CFBundleShortVersionString</key><string>1.2</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
EOF

# Copy icon
if [ -f "$PROJ_DIR/AppIcon.icns" ]; then
    cp "$PROJ_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
elif [ -f "/Applications/CookieVault.app/Contents/Resources/AppIcon.icns" ]; then
    cp "/Applications/CookieVault.app/Contents/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc sign
echo "🔏 Signing CookieVault..."
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "🚀 Installing to /Applications..."
# Kill running instance if any
pkill -x CookieVault 2>/dev/null || true
sleep 0.5

rm -rf /Applications/CookieVault.app
cp -R "$APP" /Applications/CookieVault.app
xattr -rd com.apple.quarantine /Applications/CookieVault.app 2>/dev/null || true

echo ""
echo "✅ CookieVault v1.2 installed successfully to /Applications/CookieVault.app!"
echo "   Launch with: open /Applications/CookieVault.app"
echo ""

if [ "$1" == "--launch" ]; then
    open /Applications/CookieVault.app
fi
