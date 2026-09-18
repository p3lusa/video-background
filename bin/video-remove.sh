#!/usr/bin/env bash
# video-remove.sh — remove a video from the library, everywhere.
#
# Removes the per-clip theme (video-<name>, marked .video-theme) and every
# library copy (videos/<name>.mp4 + backgrounds/<name>.png in any theme),
# prunes the cycle-list entry, and keeps the active state sane: if the clip
# being removed is the playing one, it switches to another video theme first
# (or re-points the background afterwards). It never touches your original
# clip file.
#
# Usage:
#   video-remove.sh <name>
#   <name> accepts: 07-rebecca-gun | video-07-rebecca-gun | 07-rebecca-gun.mp4

set -euo pipefail

PLUGIN_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_THEMES="$HOME/.config/omarchy/themes"
CYCLE_LIST="$HOME/.config/omarchy/video-themes"

if [[ $# -ne 1 || -z ${1:-} ]]; then
  echo "Usage: $(basename "$0") <name>" >&2
  exit 2
fi
name="$1"
name="${name%.mp4}"
name="${name#video-}"

# --- locate -------------------------------------------------------------------
perclip="$USER_THEMES/video-$name"
has_perclip=false
[[ -f "$perclip/.video-theme" ]] && has_perclip=true

declare -A lib_copies=()
for tdir in "$USER_THEMES"/*/; do
  # Check both new structure (videos/) and legacy (backgrounds/ with .mp4)
  if [[ -f "${tdir}videos/$name.mp4" ]]; then
    [[ "${tdir%/}" == "$perclip" ]] && continue
    lib_copies["${tdir%/}"]="videos"
  elif [[ -f "${tdir}backgrounds/$name.mp4" ]]; then
    [[ "${tdir%/}" == "$perclip" ]] && continue
    lib_copies["${tdir%/}"]="backgrounds"
  fi
done

if ! $has_perclip && (( ${#lib_copies[@]} == 0 )); then
  echo "error: video '$name' not found (no per-clip theme, no library copy)." >&2
  exit 1
fi

CURRENT_THEME="$(tr -d '[:space:]' < "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null || true)"
CURRENT_BG="$(readlink -f "$HOME/.local/state/omarchy/current/background" 2>/dev/null || true)"
CUR_BASE=""
if [[ -n $CURRENT_BG ]]; then
  CUR_BASE="${CURRENT_BG##*/}"
  CUR_BASE="${CUR_BASE%.*}"
fi

# paired_clip_exists <theme_dir> [exclude-base] — true if the theme has at
# least one clip whose video is paired with a poster (backgrounds/<base>.png
# + videos/<base>.mp4). Same criterion the plugin (and video-cycle.sh /
# video-switcher.sh) use to decide what can actually play. exclude-base is
# the clip currently being removed: the check must evaluate the theme as it
# will look AFTER the removal, so that clip's pairing doesn't count.
paired_clip_exists() {
  local tdir=$1 ex=${2:-} base
  [[ -d "$tdir/videos" && -d "$tdir/backgrounds" ]] || return 1
  for poster in "$tdir"/backgrounds/*; do
    [[ -f $poster ]] || continue
    base="${poster##*/}"; base="${base%.*}"
    [[ $base == "$ex" ]] && continue
    [[ -f "$tdir/videos/$base.mp4" ]] && return 0
  done
  return 1
}

# --- protect the active state --------------------------------------------------
# If the playing background is the clip being removed, move elsewhere first.
if [[ $CUR_BASE == "$name" ]]; then
  if [[ $CURRENT_THEME == "video-$name" ]] && $has_perclip; then
    # the active theme goes away: switch to another video theme
    fallback=""
    if [[ -d "$USER_THEMES/video-wallpaper/videos" ]] && \
       [[ -n $(find "$USER_THEMES/video-wallpaper/videos" -name '*.mp4' ! -name "$name.mp4" 2>/dev/null | head -1) ]]; then
      # only fall back to video-wallpaper if a remaining clip is still
      # paired with a poster (unpaired clips don't play)
      if paired_clip_exists "$USER_THEMES/video-wallpaper" "$name"; then
        fallback="video-wallpaper"
      else
        for tdir in "$USER_THEMES"/*/; do
          t="${tdir%/}"; t="${t##*/}"
          [[ $t == "video-$name" ]] && continue
          if paired_clip_exists "$tdir" "$name"; then
            fallback="$t"
            break
          fi
        done
      fi
    else
      for tdir in "$USER_THEMES"/*/; do
        t="${tdir%/}"; t="${t##*/}"
        [[ $t == "video-$name" ]] && continue
        if paired_clip_exists "$tdir" "$name"; then
          fallback="$t"
          break
        fi
      done
    fi
    if [[ -n $fallback ]]; then
      echo "switching to '$fallback' first (the playing video is being removed)…"
      omarchy theme set "$fallback" >/dev/null 2>&1
    fi
    # if no fallback exists, the heal step below re-points the background
  fi
fi

# --- remove ---------------------------------------------------------------------
if $has_perclip; then
  omarchy theme remove "video-$name" >/dev/null 2>&1 || rm -rf "$perclip"
  echo "removed per-clip theme video-$name."
fi
for t in "${!lib_copies[@]}"; do
  subdir="${lib_copies[$t]}"
  rm -f "$t/$subdir/$name.mp4" "$t/backgrounds/$name.png"
  echo "removed library copy in $t."
done

# prune the cycle-list entry
if [[ -f $CYCLE_LIST ]]; then
  awk -v n="video-$name" '$0 != n' "$CYCLE_LIST" >"$CYCLE_LIST.tmp"
  mv "$CYCLE_LIST.tmp" "$CYCLE_LIST"
fi

# --- heal: the current background must resolve -----------------------------------
staged_bg="$(readlink -f "$HOME/.local/state/omarchy/current/background" 2>/dev/null || true)"
if [[ -z $staged_bg || ! -f $staged_bg ]]; then
  staged_theme="$HOME/.local/state/omarchy/current/theme"
  first_bg="$(find "$staged_theme/backgrounds" -type f 2>/dev/null | sort | head -1)"
  if [[ -n $first_bg ]]; then
    omarchy theme bg set "$first_bg" >/dev/null 2>&1 || true
  else
    # the active theme has no backgrounds left: switch to one that does
    for tdir in "$USER_THEMES"/*/; do
      t="${tdir%/}"; t="${t##*/}"
      if [[ -n $(find "${tdir}backgrounds" -type f 2>/dev/null | head -1) ]]; then
        omarchy theme set "$t" >/dev/null 2>&1
        break
      fi
    done
  fi
fi

# reaper as a safety net (prunes anything else abandoned)
"$PLUGIN_BIN/video-cleanup.sh" || true

echo "done: '$name' removed from the library."
