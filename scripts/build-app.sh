#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift build --disable-sandbox -c release --scratch-path .build --cache-path .build/cache
bin_dir=$(swift build --disable-sandbox -c release --scratch-path .build --cache-path .build/cache --show-bin-path)
app_dir="$PWD/dist/SpotFast.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$bin_dir/SpotFast" "$app_dir/Contents/MacOS/SpotFast"
if [[ "${1:-}" == "--with-fsearch" ]]; then
    if [[ ! -x vendor/fsearch/target/release/fsearch ]]; then
        printf 'Missing tested FSearch binary. Run scripts/install.py first.\n' >&2
        exit 1
    fi
    cp vendor/fsearch/target/release/fsearch "$app_dir/Contents/MacOS/fsearch"
    /usr/bin/codesign --force --sign - "$app_dir/Contents/MacOS/fsearch"
else
    rm -f "$app_dir/Contents/MacOS/fsearch"
fi
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.spotfast.launcher</string>
<key>CFBundleName</key><string>SpotFast</string>
<key>CFBundleExecutable</key><string>SpotFast</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.1</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$app_dir"
printf 'Built %s\n' "$app_dir"
