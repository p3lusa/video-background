#!/usr/bin/env bash
# test_names.sh — adversarial clip-name handling (regression).
#
# Nasty clip file names (spaces, $(), backticks, ;, |, &, unicode) must be
# pure data everywhere: the library scan lists them verbatim, poster_for
# resolves them, and no component ever word-splits them or lets the shell
# evaluate them. Runs entirely in a temp tree; touches nothing real.

set -u
cd "$(dirname "$0")"
PASS=0 FAIL=0
ok() { echo "ok   $1"; PASS=$((PASS+1)); }
ng() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export XDG_CACHE_HOME="$TMP/cache"   # keep META_DIR/SESSION inside the temp tree

THEMES="$TMP/themes"
LIB="$THEMES/video-wallpaper"
mkdir -p "$LIB/videos" "$LIB/backgrounds"
printf 'fake' > "$LIB/videos/base.mp4"
printf 'fake' > "$LIB/backgrounds/base.png"

names=(
  'space clip one'
  'dollar $(id)'
  'btick `id`'
  'semi;touch PWN_C;'
  'pipe|amp&&'
  'uni-ñ漢字'
)
for n in "${names[@]}"; do
  cp "$LIB/videos/base.mp4" "$LIB/videos/$n.mp4"
  cp "$LIB/backgrounds/base.png" "$LIB/backgrounds/$n.png"
done

# load the TUI functions without running main
VM_NO_MAIN=1 source bin/video-manage.sh
THEMES_USER="$THEMES"
THEMES_SYS="$TMP/nonexistent"
scan_library

got=$(cut -f1 "$SESSION/library.tsv" | sort)
for n in "${names[@]}"; do
  printf '%s\n' "$got" | grep -qxF -- "$n" && ok "scan lists: $n" || ng "scan lists: $n"
  p=$(poster_for "$n")
  [[ $p == "$LIB/backgrounds/$n.png" ]] && ok "poster_for: $n" || ng "poster_for: $n"
done

# library.tsv is tab-separated: names must never split into extra rows/cols
[[ $(wc -l < "$SESSION/library.tsv") == $((${#names[@]} + 1)) ]] \
  && ok "no word-splitting in scan (${#names[@]}+base rows)" \
  || ng "word-splitting in scan: $(wc -l < "$SESSION/library.tsv") rows"

# nothing was ever executed: no marker file anywhere under the temp tree
[[ $(find "$TMP" -name 'PWN_C' -o -name 'PWN_C;' 2>/dev/null | wc -l) == 0 ]] \
  && ok "no side effects from injection names" \
  || ng "side effects from injection names"

echo "passed=$PASS failed=$FAIL"
[[ $FAIL == 0 ]]
