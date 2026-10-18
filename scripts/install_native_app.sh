#!/bin/zsh
# Build a release WalleBrain.app, sign it with the local identity, and install it to /Applications.
# The installed app keeps reading the existing data: no data is moved or copied.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

BUNDLE_NAME="WalleBrain"
BUNDLE_ID="com.wallebrain.app"
INSTALL_DIR="${WALLEBRAIN_INSTALL_DIR:-/Applications}"
TARGET_APP="$INSTALL_DIR/${BUNDLE_NAME}.app"
EXECUTABLE_NAME="WalleBrainApp"
SETTINGS_KEY="WalleBrain.DataDirectory"

# The main checkout (worktrees share it) holds the existing runtime data.
GIT_COMMON_DIR="$(git -C "$ROOT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
MAIN_ROOT_DIR="${GIT_COMMON_DIR:+$(dirname "$GIT_COMMON_DIR")}"
MAIN_ROOT_DIR="${MAIN_ROOT_DIR:-$ROOT_DIR}"

DEFAULT_DATA_DIR="${WALLEBRAIN_DEFAULT_DATA_DIR:-}"
if [[ -z "$DEFAULT_DATA_DIR" && -d "$MAIN_ROOT_DIR/runtime/native" ]]; then
  DEFAULT_DATA_DIR="$MAIN_ROOT_DIR"
fi

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wallebrain.install.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

echo "Building release bundle…" >&2
STAGED_APP="$(
  WALLEBRAIN_BUILD_CONFIGURATION=release \
  WALLEBRAIN_BUNDLE_OUTPUT_DIR="$STAGING_DIR" \
  WALLEBRAIN_DEFAULT_DATA_DIR="$DEFAULT_DATA_DIR" \
    "$ROOT_DIR/scripts/build_native_bundle.sh" "$EXECUTABLE_NAME" "$BUNDLE_NAME" "$BUNDLE_ID"
)"
codesign --verify --deep --strict "$STAGED_APP"

# Quit the installed copy if it is running, but never while a meeting is in flight:
# quitting mid-recording would cut the audio capture short.
installed_pids() {
  pgrep -f "^$TARGET_APP/Contents/MacOS/$EXECUTABLE_NAME" || true
}

if [[ -n "$(installed_pids)" ]]; then
  DATA_DIR="$(defaults read "$BUNDLE_ID" "$SETTINGS_KEY" 2>/dev/null || echo "$DEFAULT_DATA_DIR")"
  SESSIONS_DIR="${DATA_DIR%/}/runtime/native/MeetingSessions"
  if [[ -z "${WALLEBRAIN_INSTALL_FORCE:-}" && -d "$SESSIONS_DIR" ]]; then
    BUSY="$(grep -lE '^  "status" : "(preparing|recording|processing)"' "$SESSIONS_DIR"/*.session.json 2>/dev/null || true)"
    if [[ -n "$BUSY" ]]; then
      echo "WalleBrain is recording or processing a meeting; not quitting it. Finish it, then rerun." >&2
      echo "$BUSY" >&2
      echo "(Set WALLEBRAIN_INSTALL_FORCE=1 to skip this check.)" >&2
      exit 1
    fi
  fi

  echo "Quitting running $TARGET_APP…" >&2
  # Quit by pid: a dev copy with the same bundle id may be running too and must be left alone.
  for pid in ${(f)"$(installed_pids)"}; do
    osascript -l JavaScript \
      -e "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid).terminate" \
      >/dev/null 2>&1 || true
  done
  for _ in {1..60}; do
    [[ -z "$(installed_pids)" ]] && break
    sleep 0.5
  done
  if [[ -n "$(installed_pids)" ]]; then
    echo "WalleBrain did not quit within 30 seconds; quit it manually and rerun." >&2
    exit 1
  fi
fi

# Keep the previous copy until the new one is in place, so a failed copy can be rolled back.
PREVIOUS_APP="$STAGING_DIR/previous.app"
if [[ -e "$TARGET_APP" ]]; then
  mv "$TARGET_APP" "$PREVIOUS_APP"
fi
if ! ditto "$STAGED_APP" "$TARGET_APP" || ! codesign --verify --deep --strict "$TARGET_APP"; then
  echo "Install failed; restoring the previous copy." >&2
  rm -rf "$TARGET_APP"
  [[ -e "$PREVIOUS_APP" ]] && mv "$PREVIOUS_APP" "$TARGET_APP"
  exit 1
fi

echo "Installed $TARGET_APP" >&2
if [[ -n "$DEFAULT_DATA_DIR" ]]; then
  echo "Default data directory: $DEFAULT_DATA_DIR (used unless a folder is chosen in Settings)" >&2
fi
echo "$TARGET_APP"
