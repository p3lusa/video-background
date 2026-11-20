#!/usr/bin/env bash
# video-bootstrap.sh — plugin bootstrap, run by the shell service (Manager.qml)
# every time this plugin loads (enable, rescan, shell restart) — and safe to
# run by hand. Idempotent, silent when nothing needs doing.
#
# 1. self-deploy the keybinding block and the theme-menu entry;
# 2. install the companion library theme (p3lusa/video-wallpaper) when the
#    user does not have one: it is the library mirror video-add.sh links
#    clips into, and its posters+clips teach the picker. Never touched once
#    it exists (omarchy theme install would re-clone over local additions);
#    opt out entirely with the file ~/.local/state/io.github.p3lu.video-background/skip-theme

set -euo pipefail

PLUGIN_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$HOME/.local/state/io.github.p3lu.video-background"
USER_THEMES="${VIDEO_THEMES_DIR:-$HOME/.config/omarchy/themes}"
THEME_URL="${VIDEO_THEME_URL:-https://github.com/p3lusa/video-wallpaper.git}"

"$PLUGIN_BIN/video-bindings.sh" --add --quiet || true
[[ -x $PLUGIN_BIN/video-menu.sh ]] && "$PLUGIN_BIN/video-menu.sh" --add --quiet || true

theme_dir="$USER_THEMES/video-wallpaper"
if [[ -d $theme_dir || -f "$STATE_DIR/skip-theme" ]]; then
  exit 0
fi

mkdir -p "$STATE_DIR"
if [[ $theme_dir == "$HOME/.config/omarchy/themes/video-wallpaper" ]]; then
  omarchy theme install "$THEME_URL" >"$STATE_DIR/theme-install.log" 2>&1 || true
else
  # test override path: clone without omarchy's re-clone semantics
  git clone -- "$THEME_URL" "$theme_dir" >"$STATE_DIR/theme-install.log" 2>&1 || true
fi
if [[ -d $theme_dir ]]; then
  echo "installed companion theme: video-wallpaper"
else
  rm -f "$STATE_DIR/theme-install.log"
fi
exit 0
