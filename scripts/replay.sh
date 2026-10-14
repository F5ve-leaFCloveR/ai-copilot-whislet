#!/bin/bash
set -euo pipefail
COPILOT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
    printf '%s\n' "Использование: bash scripts/replay.sh <questions.jsonl>" >&2
    exit 1
fi
COPILOT_MANIFEST="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
cd "$COPILOT_ROOT"
bash scripts/build-app.sh
exec dist/Whislet.app/Contents/MacOS/InterviewCopilot --replay "$COPILOT_MANIFEST"
