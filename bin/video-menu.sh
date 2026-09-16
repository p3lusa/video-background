#!/usr/bin/env bash
# video-menu.sh — install or remove the theme-menu override in the user's
# Omarchy menu extensions.
#
# The stock "Theme" menu entry (style.theme, opened with Super+Shift+Ctrl+Space)
# runs omarchy-theme-switcher, which lists every installed theme — including
# the per-clip video themes. The override points it at
# video-theme-switcher.sh, which skips themes carrying the .video-theme
# marker, so the theme selector stays clean.
#
# The override lives in ~/.config/omarchy/extensions/omarchy-menu.jsonc
# inside a marked block. The menu hot-reloads on save. User entries outside
# the block are never touched; if the file already contains user entries
# and no block, the script prints the snippet to add manually instead of
# guessing.
#
#   video-menu.sh [--add | --remove] [--quiet]      (default: --add)

set -euo pipefail

MODE=add
QUIET=0
for arg in "$@"; do
  case "$arg" in
  --add) MODE=add ;;
  --remove) MODE=remove ;;
  --quiet) QUIET=1 ;;
  -h | --help)
    echo "Usage: $(basename "$0") [--add | --remove] [--quiet]"
    exit 0
    ;;
  *)
    echo "Unknown option: $arg" >&2
    echo "Usage: $(basename "$0") [--add | --remove] [--quiet]" >&2
    exit 1
    ;;
  esac
done

MENU_FILE="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
BEGIN_MARK="// >>> io.github.p3lu.video-background >>>"
END_MARK="// <<< io.github.p3lu.video-background <<<"
PLUGIN_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { (( QUIET )) || echo "$@"; }

# The override property as one JSONC line. Only "action" is overridden; the
# stock icon/label/aliases are kept by the menu merge.
override_line() {
  printf '  "style.theme": {"icon":"","label":"Theme","aliases":["theme","themes"],"action":"VTS=\\\"%s/video-theme-switcher.sh\\\"; if [[ -x $VTS ]]; then theme=$(\\\"$VTS\\\"); else theme=$(omarchy-theme-switcher); fi; [[ -n $theme ]] && omarchy-theme-set \\\"$theme\\\""}\n' "$PLUGIN_BIN"
}

block() {
  printf '%s\n' "$BEGIN_MARK"
  override_line
  printf '%s\n' "$END_MARK"
}

have_block() {
  [[ -f $MENU_FILE ]] && grep -qF -e "$BEGIN_MARK" "$MENU_FILE"
}

# Print $MENU_FILE without the marked block (both markers inclusive).
strip_block() {
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    index($0, b) { skip = 1; next }
    index($0, e) { skip = 0; next }
    !skip { print }
  ' "$MENU_FILE"
}

# True when the file has no JSON properties (only braces/comments/whitespace).
is_effectively_empty() {
  local content
  content="$(grep -vE '^[[:space:]]*(//|$)' "$MENU_FILE" || true)"
  content="$(printf '%s' "$content" | tr -d '{\t\n}')"
  [[ -z $content ]]
}

manual_hint() {
  say "The menu extension file has user entries and no plugin block:"
  say "  $MENU_FILE"
  say "Add this inside the top-level object:"
  block
}

if [[ $MODE == remove ]]; then
  if have_block; then
    strip_block >"$MENU_FILE.tmp"
    mv "$MENU_FILE.tmp" "$MENU_FILE"
    say "menu override removed from $MENU_FILE"
  else
    say "menu override not present; nothing to remove"
  fi
  exit 0
fi

# --add
mkdir -p "$(dirname "$MENU_FILE")"

if have_block; then
  # Refresh in place (the block may point at a stale plugin path).
  strip_block >"$MENU_FILE.tmp"
  # Re-insert before the final closing brace.
  last_brace="$(grep -n '^[[:space:]]*}' "$MENU_FILE.tmp" | tail -1 | cut -d: -f1)"
  if [[ -n $last_brace ]]; then
    head -n $((last_brace - 1)) "$MENU_FILE.tmp" >"$MENU_FILE.new"
    block >>"$MENU_FILE.new"
    tail -n +"$last_brace" "$MENU_FILE.tmp" >>"$MENU_FILE.new"
  else
    printf '%s\n' '{' >"$MENU_FILE.new"
    block >>"$MENU_FILE.new"
    printf '%s\n' '}' >>"$MENU_FILE.new"
  fi
  mv "$MENU_FILE.new" "$MENU_FILE"
  rm -f "$MENU_FILE.tmp"
  say "menu override updated in $MENU_FILE"
  exit 0
fi

if [[ ! -f $MENU_FILE ]]; then
  {
    printf '%s\n' '{'
    block
    printf '%s\n' '}'
  } >"$MENU_FILE"
  say "menu override added to $MENU_FILE"
  exit 0
fi

# File exists without our block.
if is_effectively_empty; then
  last_brace="$(grep -n '^[[:space:]]*}' "$MENU_FILE" | tail -1 | cut -d: -f1)"
  if [[ -n $last_brace ]]; then
    head -n $((last_brace - 1)) "$MENU_FILE" >"$MENU_FILE.tmp"
    block >>"$MENU_FILE.tmp"
    tail -n +"$last_brace" "$MENU_FILE" >>"$MENU_FILE.tmp"
    mv "$MENU_FILE.tmp" "$MENU_FILE"
  else
    printf '\n%s\n' "$(block)" >>"$MENU_FILE"
  fi
  say "menu override added to $MENU_FILE"
else
  manual_hint
fi
