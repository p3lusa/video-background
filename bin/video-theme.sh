#!/usr/bin/env bash
# video-theme.sh — create an Omarchy theme from a video clip.
#
# Generates a complete, palette-matched Omarchy theme from a single video:
# a poster frame is extracted, Aether derives the color palette from it, and
# the clip is installed as the theme's looping video wallpaper.
#
# Usage:
#   video-theme.sh [--no-activate] <clip.mp4> [theme-name]
#
# Example:
#   video-theme.sh ~/Videos/aurora.mp4            # theme "video-aurora"
#   video-theme.sh ~/Videos/aurora.mp4 my-aurora  # theme "my-aurora"
#
# The theme is activated immediately, and (because each clip gets its own
# theme) registered in the video-theme cycle: `video-next` / `video-prev`
# (installed alongside this helper) switch to the next/previous clip+palette
# pair with one command.
#
# Requirements: aether, ffmpeg, omarchy, and the io.github.p3lu.video-background
# plugin (to render the videos/ directory — without it, the theme shows
# the poster image instead).
#
# Notes:
#   - The theme is installed to ~/.config/omarchy/themes/<theme-name>/ and
#     marked as Aether-managed (.aether-managed), so future Aether runs
#     recognize it.
#   - Theme names must match [A-Za-z0-9][A-Za-z0-9_.-]{0,63} (lowercased).
#   - To update the clip later, replace the file in the theme's videos/
#     directory and run: omarchy theme set <theme-name>

set -euo pipefail

# Self-deploy the video keybindings (idempotent, silent; no-op when already
# present, so no Hyprland reload storms).
"$(dirname "${BASH_SOURCE[0]}")/video-bindings.sh" --add --quiet || true
# Reap abandoned per-clip themes (silent no-op when nothing to clean).
"$(dirname "${BASH_SOURCE[0]}")/video-cleanup.sh" || true
# Keep the theme menu clean (idempotent, silent).
"$(dirname "${BASH_SOURCE[0]}")/video-menu.sh" --add --quiet || true

no_activate=""
if [[ ${1:-} == "--no-activate" ]]; then
  no_activate=1
  shift
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $(basename "$0") [--no-activate] <clip.mp4> [theme-name]" >&2
  exit 2
fi

clip="$1"

# --- sanity checks ------------------------------------------------------------
if [[ ! -f "$clip" ]]; then
  echo "error: clip not found: $clip" >&2
  exit 1
fi
for tool in aether ffmpeg ffprobe omarchy; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: required tool not found: $tool" >&2
    exit 1
  fi
done

# Theme name: explicit, or derived from the clip (video-<clip base>).
# Valid theme names: [A-Za-z0-9][A-Za-z0-9_.-]{0,63}.
clip_base="$(basename "$clip")"
clip_base="${clip_base%.*}"
if [[ $# -eq 2 ]]; then
  name="$(tr '[:upper:]' '[:lower:]' <<< "$2")"
else
  # sanitize: lowercase, keep [a-z0-9_.-], anything else -> '-', trim edges.
  s="$(tr '[:upper:]' '[:lower:]' <<< "$clip_base" | tr -c 'a-z0-9_.-' '-' | tr -d '\n' | sed -e 's/^-*//' -e 's/-*$//')"
  name="video-${s:0:58}"
fi
if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]]; then
  echo "error: invalid theme name: $name" >&2
  echo "       (letters, digits, '_', '.', '-'; must start with a letter/digit)" >&2
  exit 1
fi
theme_src="${HOME}/.config/omarchy/themes/${name}"
if [[ -d "$theme_src" ]]; then
  echo "error: theme already exists: $name ($theme_src)" >&2
  echo "       delete it or pick another name." >&2
  exit 1
fi

# --- 1. poster frame ------------------------------------------------------------
# A frame from ~10% into the clip: representative of the whole loop for
# seamless loops, and stable. Falls back to 0s for very short clips.
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
poster="${tmpdir}/poster.png"

duration="$(ffprobe -v error -show_entries format=duration \
  -of default=nw=1:nk=1 "$clip" 2>/dev/null || echo 0)"
seek="$(awk -v d="${duration:-0}" 'BEGIN { s = d * 0.1; if (s < 0) s = 0; printf "%.2f", s }')"
if ! ffmpeg -hide_banner -loglevel error -ss "$seek" -i "$clip" \
    -frames:v 1 -y "$poster" || [[ ! -s "$poster" ]]; then
  echo "error: could not extract a poster frame from $clip" >&2
  exit 1
fi

# --- 2. generate + install theme --------------------------------------------------
# Aether writes a full theme (colors.toml + terminal/tool configs) to a temp
# dir; we move it into Omarchy's user themes root and mark it Aether-managed
# (same marker aether --handle-url would leave behind).
gen_dir="${tmpdir}/theme"
if ! aether --generate "$poster" --no-apply --output "$gen_dir" >/dev/null; then
  echo "error: aether failed to generate a theme from the poster" >&2
  exit 1
fi
if [[ ! -f "$gen_dir/colors.toml" ]]; then
  echo "error: aether produced no colors.toml in $gen_dir" >&2
  exit 1
fi
mkdir -p "$theme_src"
cp -r "$gen_dir/." "$theme_src/"
echo "aether" > "${theme_src}/.aether-managed"
# Plugin marker: video-cleanup.sh only ever touches themes that carry it
# (never the multi-clip library theme or normal themes).
printf 'clip=%s\ncreated=%s\n' "$(basename "$clip")" "$(date -Is)" > "${theme_src}/.video-theme"

# --- 3. attach the video -----------------------------------------------------------
# The video plugin derives the playing clip from the active background image's
# base name, so the poster must carry the clip's base name. Rename whatever
# poster Aether generated to match.
clip_base="$(basename "$clip")"
clip_base="${clip_base%.*}"
mkdir -p "${theme_src}/videos"
cp "$clip" "${theme_src}/videos/$(basename "$clip")"
poster_file="$(find "${theme_src}/backgrounds" -maxdepth 1 -name '*.png' 2>/dev/null | head -1)"
if [[ -n "$poster_file" ]]; then
  mv "$poster_file" "${theme_src}/backgrounds/${clip_base}.png"
fi

# --- 4. activate (skippable: --no-activate keeps the current wallpaper) -------------
if [[ -n $no_activate ]]; then
  echo "skipping activation (--no-activate); current wallpaper unchanged."
else
  if ! omarchy theme set "$name"; then
    echo "error: omarchy theme set $name failed" >&2
    exit 1
  fi
fi

# --- 5. register in the video-theme cycle ----------------------------------------
# One theme per clip means "change video" == "change theme". The cycle is an
# explicit ordered list (creation order); video-next / video-prev walk it.
cycle_list="${HOME}/.config/omarchy/video-themes"
if ! grep -qxF "$name" "$cycle_list" 2>/dev/null; then
  echo "$name" >> "$cycle_list"
fi

echo
if [[ -n $no_activate ]]; then
  echo "Theme '$name' created (not activated)."
else
  echo "Theme '$name' is active."
fi
echo "  source: $theme_src"
echo "  video : videos/$(basename "$clip")"
echo "  cycle : video-next / video-prev (registered in $cycle_list)"
