#!/usr/bin/env bash
# Reads config.local.json (copy config.example.json and fill it in), writes
# the gitignored resources-personal/ overlay, and builds BGGlance.prg with
# personal.jungle — the sideload variant with your server URL and token
# baked in. See README.md for the generic (store) build, which ships empty
# defaults and is configured from the Garmin Connect phone app instead.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-config.local.json}"
if [ ! -f "$CONFIG" ]; then
    echo "Missing $CONFIG — copy config.example.json to config.local.json and fill it in." >&2
    exit 1
fi

python3 tools/render_overlay.py "$CONFIG"

DEVICE=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['device'])" "$CONFIG")
DEVKEY=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['developerKey'])" "$CONFIG")

monkeyc -d "$DEVICE" -f personal.jungle -o BGGlance.prg -y "$DEVKEY"
echo "Built BGGlance.prg for $DEVICE"
