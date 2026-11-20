#!/usr/bin/env bash
# test_picker.sh — the Super+Ctrl+Space dispatcher must open the video
# switcher for themes whose clips live in backgrounds/ (native layout) OR
# videos/ (legacy), and fall back to the stock picker for image themes.
# Regression guard: after the layout migration the old check looked only at
# videos/ and every video theme silently fell through to the stock picker.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
PASS=0; FAIL=0
ok()  { echo "ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL+1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
sed -e 's#exec "$PLUGIN_BIN/video-switcher.sh"#echo SWITCHER#' \
    -e 's#exec omarchy-menu toggle background#echo NATIVE#' \
    bin/video-bg-picker.sh > "$T/picker.sh"
mkdir -p "$T/.local/state/omarchy/current"
link() { rm -f "$T/.local/state/omarchy/current/theme"; ln -s "$1" "$T/.local/state/omarchy/current/theme"; }
out() { HOME=$T bash "$T/picker.sh" 2>/dev/null; }

mkdir -p "$T/native/backgrounds"
touch "$T/native/backgrounds/clip.png" "$T/native/backgrounds/clip.mp4"
link "$T/native"; [[ $(out) == SWITCHER ]] && ok "backgrounds/ clip -> switcher" || bad "backgrounds/ clip -> switcher"

mkdir -p "$T/legacy/videos" "$T/legacy/backgrounds"
touch "$T/legacy/videos/old.mp4" "$T/legacy/backgrounds/old.png"
link "$T/legacy"; [[ $(out) == SWITCHER ]] && ok "legacy videos/ clip -> switcher" || bad "legacy videos/ clip -> switcher"

rm -f "$T/native/backgrounds/clip.mp4"
link "$T/native"; [[ $(out) == NATIVE ]] && ok "images only -> stock picker" || bad "images only -> stock picker"

# non-video extensions must not count as clips
touch "$T/native/backgrounds/document.pdf"
link "$T/native"; [[ $(out) == NATIVE ]] && ok "pdf in backgrounds -> stock picker" || bad "pdf in backgrounds -> stock picker"

echo "passed=$PASS failed=$FAIL"
(( FAIL == 0 ))
