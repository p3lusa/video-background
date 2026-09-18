#!/bin/bash
# io.github.p3lu.video-background: install or remove the video keybindings in the
# user's Hyprland bindings (~/.config/hypr/bindings.lua).
#
# The bindings live in a self-contained, marked block. --add appends the
# block (or replaces an existing one in place); --remove strips it. User
# lines outside the block are never touched. A Hyprland reload follows any
# actual change.
#
#   video-bindings.sh [--add | --remove] [--quiet]      (default: --add)

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

# Bindings always point at the INSTALLED plugin — the live copy managed by
# omarchy — never at a development checkout. This script is also run from
# the git repo (video-theme.sh, video-cycle.sh, video-switcher.sh invoke it
# as $(dirname $0)/video-bindings.sh), so a self-relative path would silently
# point the keybindings at whatever tree was invoked. Develop in the repo,
# deploy to the installed plugin, and the keybindings always run the
# installed copy. Fall back to our own directory only when no install
# exists yet (e.g. first run before the plugin is in place).
PLUGIN_BIN="$HOME/.config/omarchy/plugins/io.github.p3lu.video-background/bin"
[[ -d $PLUGIN_BIN ]] || PLUGIN_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINDINGS_FILE="$HOME/.config/hypr/bindings.lua"
BEGIN_MARK="-- >>> io.github.p3lu.video-background >>>"
END_MARK="-- <<< io.github.p3lu.video-background <<<"

say() { (( QUIET )) || echo "$@"; }

reload_if_hyprland() {
  command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1 || true
}

# Print $BINDINGS_FILE without the marked block (both markers inclusive).
strip_block() {
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    index($0, b) { skip = 1; next }
    index($0, e) { skip = 0; next }
    !skip { print }
  ' "$BINDINGS_FILE"
}

block_content() {
  cat <<EOF
-- Replaces the stock "Background switcher" key (Super+Ctrl+Space) with the
-- unified wallpaper picker: video switcher on video themes, stock background
-- picker on image themes. The dedicated switcher key is no longer needed.
hl.unbind("SUPER + CTRL + SPACE")
o.bind("SUPER + CTRL + SPACE", "Wallpaper switcher", "$PLUGIN_BIN/video-bg-picker.sh")
o.bind("SUPER + CTRL + ALT + LEFT", "Previous wallpaper video", "$PLUGIN_BIN/video-prev.sh")
o.bind("SUPER + CTRL + ALT + RIGHT", "Next wallpaper video", "$PLUGIN_BIN/video-next.sh")
o.bind("SUPER + CTRL + ALT + V", "Video library manager", "xdg-terminal-exec $PLUGIN_BIN/video-manage.sh")
EOF
}

block() {
  printf '%s\n' "$BEGIN_MARK"
  block_content
  printf '%s\n' "$END_MARK"
}

have_block() {
  [[ -f $BINDINGS_FILE ]] && grep -qF -e "$BEGIN_MARK" "$BINDINGS_FILE"
}

if [[ $MODE == remove ]]; then
  if have_block; then
    strip_block >"$BINDINGS_FILE.tmp"
    mv "$BINDINGS_FILE.tmp" "$BINDINGS_FILE"
    reload_if_hyprland
    say "video bindings removed from $BINDINGS_FILE"
  else
    say "video bindings not present; nothing to remove"
  fi
  exit 0
fi

# --add
mkdir -p "$(dirname "$BINDINGS_FILE")"

new_block="$(block)"
new_content="$(block_content)"

if have_block; then
  current_block="$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    index($0, b) { inside = 1; next }
    index($0, e) { inside = 0; next }
    inside { print }
  ' "$BINDINGS_FILE")"
  if [[ "$current_block" == "$new_content" ]]; then
    exit 0 # nothing changed: no write, no reload
  fi
  # Replace in place is not worth the complexity: strip the old block and
  # append the fresh one at the end of the file.
  strip_block >"$BINDINGS_FILE.tmp"
  printf '\n%s\n' "$new_block" >>"$BINDINGS_FILE.tmp"
  mv "$BINDINGS_FILE.tmp" "$BINDINGS_FILE"
  reload_if_hyprland
  say "video bindings updated in $BINDINGS_FILE"
else
  {
    [[ -s $BINDINGS_FILE ]] && printf '\n'
    printf '%s\n' "$new_block"
  } >>"$BINDINGS_FILE"
  reload_if_hyprland
  say "video bindings added to $BINDINGS_FILE"
fi
