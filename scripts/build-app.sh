#!/bin/zsh
# Собирает Карман.app в build/ и, с флагом --install, ставит в /Applications.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release
BIN=$(swift build -c release --show-bin-path)/Karman
APP="build/Карман.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Karman"

# Иконка из Resources/icon-1024.png.
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Карман</string>
  <key>CFBundleDisplayName</key><string>Карман</string>
  <key>CFBundleIdentifier</key><string>ru.chernov.karman</string>
  <key>CFBundleExecutable</key><string>Karman</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppSleepDisabled</key><true/>
  <key>NSDesktopFolderUsageDescription</key><string>Чтобы класть на полку последний скриншот с Рабочего стола.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Собрано: $APP"

if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'quit app id "ru.chernov.karman"' 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/Карман.app"
  ditto "$APP" "/Applications/Карман.app"
  open "/Applications/Карман.app"
  echo "Установлено в /Applications и запущено"
fi
