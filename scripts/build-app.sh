#!/bin/bash
set -euo pipefail
COPILOT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$COPILOT_ROOT"
bash scripts/swift-env.sh swift build -c release
COPILOT_BIN="$(bash scripts/swift-env.sh swift build -c release --show-bin-path)"
COPILOT_APP="$COPILOT_ROOT/dist/Whislet.app"
mkdir -p "$COPILOT_ROOT/dist"
COPILOT_STAGE="$(mktemp -d "$COPILOT_ROOT/dist/.build.XXXXXX")"
trap 'rm -rf "$COPILOT_STAGE"' EXIT
COPILOT_STAGED_APP="$COPILOT_STAGE/Whislet.app"
mkdir -p "$COPILOT_STAGED_APP/Contents/MacOS" "$COPILOT_STAGED_APP/Contents/Resources/sidecar"
cp "$COPILOT_BIN/InterviewCopilot" "$COPILOT_STAGED_APP/Contents/MacOS/InterviewCopilot"
cp Resources/Info.plist "$COPILOT_STAGED_APP/Contents/Info.plist"
for COPILOT_ICON in Resources/AppIcon.icns Resources/AppIcon.png; do
    if [ -f "$COPILOT_ICON" ]; then cp "$COPILOT_ICON" "$COPILOT_STAGED_APP/Contents/Resources/"; fi
done
cp sidecar/*.py sidecar/requirements.txt sidecar/model-manifest.json "$COPILOT_STAGED_APP/Contents/Resources/sidecar/"
if [ -d sidecar/models ]; then cp -R sidecar/models "$COPILOT_STAGED_APP/Contents/Resources/sidecar/"; fi
bash scripts/sign-app.sh "$COPILOT_STAGED_APP"
if [ -d "$COPILOT_APP" ]; then mv "$COPILOT_APP" "$COPILOT_STAGE/previous.app"; fi
if ! mv "$COPILOT_STAGED_APP" "$COPILOT_APP"; then
    if [ -d "$COPILOT_STAGE/previous.app" ]; then mv "$COPILOT_STAGE/previous.app" "$COPILOT_APP"; fi
    exit 1
fi
printf '%s\n' "$COPILOT_APP"
