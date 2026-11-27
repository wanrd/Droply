#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

swift build --disable-sandbox -c release

package_app() {
    local app_name="$1"
    local executable_name="$2"
    local bundle_id="$3"
    local include_local_network_desc="$4"

    local app_dir="$SCRIPT_DIR/build/${app_name}.app"
    rm -rf "$app_dir"
    mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"

    cp "$SCRIPT_DIR/.build/release/${executable_name}" "$app_dir/Contents/MacOS/${executable_name}"
    if [ -f "$SCRIPT_DIR/Resources/AppIcon.icns" ]; then
        cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
    fi

    local local_net_xml=""
    if [ "$include_local_network_desc" = "yes" ]; then
        local_net_xml="    <key>NSLocalNetworkUsageDescription</key>
    <string>Droply использует локальную сеть Wi-Fi для прямой передачи файлов с Android без серверов.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_droply._tcp</string>
    </array>"
    fi

    cat > "$app_dir/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${executable_name}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${bundle_id}</string>
    <key>CFBundleDisplayName</key>
    <string>${app_name}</string>
    <key>CFBundleName</key>
    <string>${app_name}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
${local_net_xml}
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

    echo "Built $app_dir"
    codesign --force --deep --sign - "$app_dir"
    echo "Signed $app_dir"
}

rm -rf "$SCRIPT_DIR/build/WiFiDrop.app"
package_app "Droply" "DroplyMac" "com.droply.mac" "yes"
package_app "Droply Admin" "DroplyAdmin" "com.droply.admin" "no"
