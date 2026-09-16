#!/usr/bin/env bash
# video-add.sh — add a clip to the video library.
#
# Creates the per-clip theme (its own Aether palette) via video-theme.sh and
# mirrors the clip into the library theme (video-wallpaper) so it also plays
# when that theme is active. The mirror uses hardlinks: zero extra space.
#
# The clip must have no audio track — the plugin has no volume control, so a
# clip with audio would be heard. --strip-audio drops the audio stream first
# (lossless remux). Non-.mp4 containers are remuxed to .mp4 automatically
# (lossless, -c copy). The name is derived from the file name: rename the
# file before adding if you want a different name.
#
# Usage:
#   video-add.sh [--strip-audio] [--no-activate] <clip>

set -euo pipefail

PLUGIN_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_THEMES="$HOME/.config/omarchy/themes"
LIBRARY_THEME="video-wallpaper"
TMP_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/video-add"

strip_audio=""
no_activate=""
while [[ ${1:-} == --* ]]; do
  case "$1" in
    --strip-audio) strip_audio="-an" ;;
    --no-activate) no_activate="--no-activate" ;;
    *) echo "error: unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ $# -ne 1 || ! -f ${1:-} ]]; then
  echo "Usage: $(basename "$0") [--strip-audio] [--no-activate] <clip>" >&2
  echo "       the clip name becomes the video name (rename the file first)." >&2
  exit 2
fi
clip="$1"
base="$(basename "$clip")"
name="${base%.*}"

# --- normalize: remux to .mp4 and/or strip audio (lossless) -----------------
need_tmp=""
case "$clip" in *.mp4) ;; *) need_tmp=1 ;; esac
if ffprobe -v error -select_streams a -show_entries stream=codec_type \
    "$clip" 2>/dev/null | grep -q audio; then
  if [[ -n $strip_audio ]]; then
    need_tmp=1
  else
    echo "error: '$base' has an audio track; the plugin would play it." >&2
    echo "       re-run with --strip-audio to drop the audio (lossless)." >&2
    exit 1
  fi
fi
if [[ -n $need_tmp ]]; then
  mkdir -p "$TMP_DIR"
  out="$TMP_DIR/$name.mp4"
  rm -f "$out"
  # -an only when stripping audio; build as an array so the (empty) case
  # doesn't leave an unquoted expansion in a command.
  ffmpeg_args=(-v error -y -i "$clip" -c:v copy)
  [[ -n $strip_audio ]] && ffmpeg_args+=(-an)
  if ! ffmpeg "${ffmpeg_args[@]}" "$out"; then
    rm -f "$out"
    echo "error: could not remux '$base' (re-encode it to H.264/.mp4 first)." >&2
    exit 1
  fi
  trap 'rm -f "$out"' EXIT
  clip="$out"
fi

# --- already present? ---------------------------------------------------------
if [[ -f "$USER_THEMES/video-$name/.video-theme" ]]; then
  echo "error: per-clip theme 'video-$name' already exists." >&2
  echo "       remove it first: video-remove.sh $name" >&2
  exit 1
fi
for tdir in "$USER_THEMES"/*/; do
  if [[ -f "${tdir}videos/$name.mp4" ]]; then
    echo "error: '$name' already exists in theme '${tdir%/}'." >&2
    echo "       remove it first: video-remove.sh $name" >&2
    exit 1
  fi
done

# --- create the per-clip theme (Aether palette) --------------------------------
echo "creating per-clip theme video-$name (Aether)…"
if [[ -n $no_activate ]]; then
  "$PLUGIN_BIN/video-theme.sh" --no-activate "$clip" "video-$name"
else
  "$PLUGIN_BIN/video-theme.sh" "$clip" "video-$name"
fi

# --- mirror into the library theme (hardlinks, zero extra space) -------------
lib="$USER_THEMES/$LIBRARY_THEME"
if [[ -d $lib ]]; then
  mkdir -p "$lib/videos" "$lib/backgrounds"
  ln -f "$USER_THEMES/video-$name/videos/$name.mp4" "$lib/videos/$name.mp4"
  ln -f "$USER_THEMES/video-$name/backgrounds/$name.png" "$lib/backgrounds/$name.png"
  echo "mirrored into $LIBRARY_THEME (hardlinks)."
else
  echo "note: library theme '$LIBRARY_THEME' not found; skipped the mirror."
fi

if [[ -n $no_activate ]]; then
  echo "done: video-$name added (not activated — play it from the TUI)."
else
  echo "done: video-$name is active. Cycle: Super+Ctrl+Alt+Left/Right."
fi

# --- GPU acceleration: first clip triggers auto-detection + apply --------------
# Idempotent; only acts while the video-background plugin is enabled, and is a
# no-op (with a message) when no GPU hwaccel is available. Runs best-effort so
# it never fails the add.
SHELL_JSON="$HOME/.config/omarchy/shell.json"
if [[ -x "$PLUGIN_BIN/video-hwaccel.sh" ]]; then
  plugin_on=$(jq -r '[.plugins[]?.id // empty] | index("io.github.p3lu.video-background")' "$SHELL_JSON" 2>/dev/null || echo null)
  if [[ "$plugin_on" != "null" ]]; then
    echo "configuring GPU video decode…"
    "$PLUGIN_BIN/video-hwaccel.sh" --apply || true
  fi
fi
