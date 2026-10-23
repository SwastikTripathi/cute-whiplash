#!/usr/bin/env bash
# Renders headless demo frames (PNG + contact sheet) without showing any window.
#   scripts/demo.sh list
#   scripts/demo.sh whip            # every demo named whip.*
#   scripts/demo.sh fx.shatter out/ # one demo, custom output dir
set -euo pipefail
cd "$(dirname "$0")/.."
NAME="${1:-list}"
OUT="${2:-demo-out}"
swift build -c debug >/dev/null
"$(swift build -c debug --show-bin-path)/Whiplash" --demo "$NAME" --out "$OUT"
