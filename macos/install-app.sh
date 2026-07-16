#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
DESTINATION="${1:-$HOME/Applications/Clash Fastest Node.app}"

DESTINATION="${DESTINATION:A}"
DESTINATION_PARENT="${DESTINATION:h}"
DESTINATION_NAME="${DESTINATION:t}"
TMP_ROOT="${TMPDIR:-/tmp}"
TMP_ROOT="${TMP_ROOT:A}"
SYSTEM_TMP="/tmp"
SYSTEM_TMP="${SYSTEM_TMP:A}"

if [[ "$DESTINATION_NAME" != *.app || "$DESTINATION_NAME" == ".app" ]]; then
  echo "Refusing unsafe destination (must be a named .app bundle): $DESTINATION" >&2
  exit 2
fi

case "$DESTINATION_PARENT" in
  "$HOME/Applications"|/Applications|"$SYSTEM_TMP"|"$TMP_ROOT") ;;
  *)
    echo "Refusing unsafe destination outside Applications or the temporary directory: $DESTINATION" >&2
    exit 2
    ;;
esac

mkdir -p "$DESTINATION_PARENT"
rm -rf "$DESTINATION"
mkdir -p "$DESTINATION/Contents/MacOS" "$DESTINATION/Contents/Resources"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/clash-refresh-clang-cache"
clang -fobjc-arc -fmodules "$SCRIPT_DIR/ClashMenuBar.m" -o "$DESTINATION/Contents/MacOS/ClashFastestNode" -framework Cocoa -framework UserNotifications
cp "$SCRIPT_DIR/clash-refresh.command" "$DESTINATION/Contents/Resources/"
CONFIG_SOURCE="$PROJECT_DIR/config.json"
[[ -f "$CONFIG_SOURCE" ]] || CONFIG_SOURCE="$PROJECT_DIR/config.example.json"
cp "$CONFIG_SOURCE" "$DESTINATION/Contents/Resources/config.json"
chmod 600 "$DESTINATION/Contents/Resources/config.json"

plutil -create xml1 "$DESTINATION/Contents/Info.plist"
plutil -insert CFBundleName -string "Clash Fastest Node" "$DESTINATION/Contents/Info.plist"
plutil -insert CFBundleDisplayName -string "Clash Fastest Node" "$DESTINATION/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string "com.local.clash-fastest-node" "$DESTINATION/Contents/Info.plist"
plutil -insert CFBundleExecutable -string "ClashFastestNode" "$DESTINATION/Contents/Info.plist"
plutil -insert CFBundlePackageType -string "APPL" "$DESTINATION/Contents/Info.plist"
plutil -insert CFBundleInfoDictionaryVersion -string "6.0" "$DESTINATION/Contents/Info.plist"
plutil -insert CFBundleDevelopmentRegion -string "en" "$DESTINATION/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string "2.0" "$DESTINATION/Contents/Info.plist"
plutil -insert CFBundleVersion -string "2" "$DESTINATION/Contents/Info.plist"
plutil -insert LSMinimumSystemVersion -string "13.0" "$DESTINATION/Contents/Info.plist"
plutil -insert LSUIElement -bool YES "$DESTINATION/Contents/Info.plist"
plutil -insert NSUserNotificationAlertStyle -string "banner" "$DESTINATION/Contents/Info.plist"

# The app bundle can live anywhere, so store the project location in its launcher.
sed -i '' "s|PROJECT_DIR=\"\${SCRIPT_DIR:h}\"|PROJECT_DIR=\"$PROJECT_DIR\"|" "$DESTINATION/Contents/Resources/clash-refresh.command"
chmod +x "$DESTINATION/Contents/Resources/clash-refresh.command"

# Updating Info.plist invalidates osacompile's original signature. Re-sign so
# macOS notification permissions can consistently identify this bundle ID.
codesign --force --deep --sign - "$DESTINATION"

# Make the generated app immediately discoverable by Spotlight and Shortcuts.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$DESTINATION" || echo "Warning: Launch Services registration will occur when the app is first opened."
fi

echo "Installed: $DESTINATION"
echo "Open it once to show the live latency in the menu bar. Reopen it to test and switch to the fastest node."
