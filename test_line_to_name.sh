#!/usr/bin/env bash
# Diagnostic: does line_to_name() recover the EXACT clip name from every
# rendered library row? This is the fragile link in the remove flow — if a
# name is mis-recovered, video-remove.sh gets the wrong name and fails.
set +e
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PLUGIN_BIN="$HERE/bin"
SRC="$PLUGIN_BIN/video-manage.sh"

# Build a sanitized copy: no set -euo, no main, no interactive session setup,
# PLUGIN_BIN pinned — so we can source it headlessly.
TMP="$(mktemp /tmp/vm-sanitized.XXXXXX)"
sed -e 's/^set -euo pipefail/set +e/' \
    -e "s|^PLUGIN_BIN=.*|PLUGIN_BIN=\"$PLUGIN_BIN\"|" \
    -e 's|^SESSION=.*|SESSION=""; |' \
    -e '/^main "\$@"$/d' \
    -e '/^trap .EXIT/d' \
    -e '/^mkdir -p "\$META_DIR"$/d' \
    "$SRC" > "$TMP"
# VM_NO_MAIN=1 keeps the script from running the TUI when sourced.
export VM_NO_MAIN=1
source "$TMP"
rm -f "$TMP"
set +euo pipefail

# Fresh session dir so scan_library has somewhere to write.
SESSION="$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/video-manage/session.XXXXXX")"
export SESSION
META_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/video-manage/meta"
export META_DIR
mkdir -p "$META_DIR"
CUR_THEME=""; CUR_BASE=""; export CUR_THEME CUR_BASE
ACC="#5FB3FF" TXT="#E4E4E4" MUT="#959DA5"; export ACC TXT MUT

scan_library

pass=0; fail=0; total=0
while IFS=$'\t' read -r name theme file kind; do
  total=$((total+1))
  line=$(render_clip "$name" "$theme" "$file" "$kind")
  recovered=$(line_to_name "$line")
  if [[ "$recovered" == "$name" ]]; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    printf 'MISMATCH\n  orig      = [%s]  (%d chars)\n  recovered = [%s]  (%d chars)\n' \
      "$name" "${#name}" "$recovered" "${#recovered}"
  fi
done < "$SESSION/library.tsv"

echo "----------------------------------------"
printf 'total=%d  ok=%d  FAIL=%d\n' "$total" "$pass" "$fail"
(( fail == 0 )) && echo "RESULT: line_to_name recovers every name correctly" || echo "RESULT: line_to_name is CORRUPTING names (this breaks remove)"
rm -rf "$SESSION"
