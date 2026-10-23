#!/usr/bin/env bash
# Builds and launches Whiplash.app. Extra args are passed to the app, e.g.
#   scripts/run.sh --threshold 20      # whip after 20s of terminal
#   scripts/run.sh --whip-now          # punish right away
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh "${CONFIG:-release}"
pkill -x Whiplash 2>/dev/null || true
# -g: launch in the background. Activating Whiplash would take the keyboard from the terminal and make the watcher
# (and --whip-now's aim) see Whiplash, not the terminal, as the frontmost app.
open -g -n build/Whiplash.app --args "$@"
