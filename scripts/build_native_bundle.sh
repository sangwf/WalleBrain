#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

PRODUCT_NAME="${1:-WalleBrainApp}"
BUNDLE_NAME="${2:-WalleBrain}"
BUNDLE_ID="${3:-com.wallebrain.app}"
SIGNING_IDENTITY="${WALLEBRAIN_CODESIGN_IDENTITY:-WalleBrain Local Signing}"

swift build --product "$PRODUCT_NAME" >&2

APP_DIR="$ROOT_DIR/runtime/native/${BUNDLE_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE="$ROOT_DIR/.build/debug/$PRODUCT_NAME"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$EXECUTABLE" "$MACOS_DIR/$PRODUCT_NAME"
chmod +x "$MACOS_DIR/$PRODUCT_NAME"

ICON_SOURCE="$ROOT_DIR/wallebrain-app-icon-v3.png"
if [[ ! -f "$ICON_SOURCE" ]]; then
  ICON_SOURCE="$ROOT_DIR/wallebrain-app-icon-v2.png"
fi
if [[ ! -f "$ICON_SOURCE" ]]; then
  ICON_SOURCE="$ROOT_DIR/wallebrain.png"
fi
ICON_NAME="AppIcon"

if [[ -f "$ICON_SOURCE" ]]; then
  ICON_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wallebrain.icon.XXXXXX")"
  ICONSET_DIR="$ICON_TMP_DIR/${ICON_NAME}.iconset"
  mkdir -p "$ICONSET_DIR"
  ICON_SIZES=(16 32 128 256 512)

  for size in "${ICON_SIZES[@]}"; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -z "$double_size" "$double_size" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
  done

  iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/${ICON_NAME}.icns"
  rm -rf "$ICON_TMP_DIR"
fi

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${PRODUCT_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>${ICON_NAME}</string>
  <key>CFBundleName</key>
  <string>${BUNDLE_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>WalleBrain records meeting audio to generate live transcripts and notes.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>WalleBrain uses speech recognition to create live meeting transcripts.</string>
</dict>
</plist>
EOF

KEYCHAIN_PATH="$("$ROOT_DIR/scripts/ensure_local_codesign_identity.sh")"
SIGNING_HASH="$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" | awk 'NR==1{print $2}')"
if [[ -z "$SIGNING_HASH" ]]; then
  echo "No valid signing identity found in $KEYCHAIN_PATH" >&2
  exit 1
fi

ORIGINAL_KEYCHAINS=("${(@f)$(security list-keychains -d user | tr -d '\"')}")
security list-keychains -d user -s "$KEYCHAIN_PATH" "${ORIGINAL_KEYCHAINS[@]}" >/dev/null
trap 'security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" >/dev/null' EXIT

codesign --force --deep --sign "$SIGNING_HASH" "$APP_DIR" >/dev/null 2>&1

echo "$APP_DIR"
