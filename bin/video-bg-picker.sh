#!/usr/bin/env bash
# video-bg-picker.sh — unified wallpaper picker.
#
# Dispatcher for the unified wallpaper key (Super+Ctrl+Space). When the
# active theme ships video clips (in backgrounds/ since the native-layout
# migration; videos/ is the legacy location) it opens the video switcher —
# the carousel of every clip in every video theme. Otherwise it falls back
# to the stock background picker, so image themes behave exactly as before.

set -euo pipefail

PLUGIN_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

has_clips() { # <dir> — any playable clip inside?
  local e
  for e in mp4 mkv webm mov avi; do
    compgen -G "$1/*.$e" >/dev/null && return 0
  done
  return 1
}

STAGED="${HOME}/.local/state/omarchy/current/theme"
if has_clips "$STAGED/videos" || has_clips "$STAGED/backgrounds"; then
  exec "$PLUGIN_BIN/video-switcher.sh"
else
  exec omarchy-menu toggle background
fi
