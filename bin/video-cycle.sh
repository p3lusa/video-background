#!/usr/bin/env bash
# video-cycle.sh — switch to the next (or previous) video in the library.
#
# The library is the same set the switcher shows: every clip of every user
# theme that has videos (a background poster with a paired video in
# backgrounds/, or the legacy videos/ subdir). Theme order: the cycle list
# first (~/.config/omarchy/
# video-themes, maintained by video-theme.sh), then any remaining video
# themes alphabetically. Clips within a theme are alphabetical.
#
# Switching to a clip of another theme runs `omarchy theme set` (video +
# palette change); switching to a clip of the current theme only runs
# `omarchy theme bg set` (palette stays).
#
# Usage:
#   video-cycle.sh next
#   video-cycle.sh prev
#
# The wrappers video-next.sh / video-prev.sh call this script.

set -euo pipefail

# Self-deploy the video keybindings (idempotent, silent; no-op when already
# present, so no Hyprland reload storms).
"$(dirname "${BASH_SOURCE[0]}")/video-bindings.sh" --add --quiet || true
# Reap abandoned per-clip themes (silent no-op when nothing to clean).
"$(dirname "${BASH_SOURCE[0]}")/video-cleanup.sh" || true
# Keep the theme menu clean (idempotent, silent).
"$(dirname "${BASH_SOURCE[0]}")/video-menu.sh" --add --quiet || true

if [[ $# -ne 1 || ( "$1" != "next" && "$1" != "prev" ) ]]; then
  echo "Usage: $(basename "$0") <next|prev>" >&2
  exit 2
fi
direction="$1"

# --- paired clip lookup -------------------------------------------------------
# videos/<base>.* = legacy layout; backgrounds/<base>.* = native Omarchy
# layout (clip stored beside its poster).
paired_video() { # <theme-dir> <base> → clip path or empty
  local d=$1 b=$2 e
  for e in mp4 mkv webm mov avi; do
    [[ -f "$d/videos/$b.$e" ]] && { printf '%s' "$d/videos/$b.$e"; return 0; }
    [[ -f "$d/backgrounds/$b.$e" ]] && { printf '%s' "$d/backgrounds/$b.$e"; return 0; }
  done
  return 0
}

USER_THEMES="$HOME/.config/omarchy/themes"
list="$HOME/.config/omarchy/video-themes"
CURRENT_THEME="$(tr -d '[:space:]' < "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null || echo "")"
CURRENT_BG="$(readlink -f "$HOME/.local/state/omarchy/current/background" 2>/dev/null || true)"
CUR_BASE=""
if [[ -n $CURRENT_BG ]]; then
  CUR_BASE="${CURRENT_BG##*/}"
  CUR_BASE="${CUR_BASE%.*}"
fi

# --- scan the library: themes that have at least one clip ------------------
declare -A theme_clips=()
for tdir in "$USER_THEMES"/*/; do
  [[ -d $tdir ]] || continue
  [[ -d "$tdir/backgrounds" ]] || continue
  t="${tdir%/}"; t="${t##*/}"
  clips=()
  declare -A seen_base=()
  for poster in "$tdir"/backgrounds/*; do
    [[ -f $poster ]] || continue
    pb="${poster##*/}"; pe="${pb##*.}"; pe="${pe,,}"
    case "$pe" in png|jpg|jpeg|webp|gif|bmp) ;; *) continue ;; esac
    base="${pb%.*}"
    [[ -z ${seen_base[$base]:-} ]] || continue
    [[ -n $(paired_video "$tdir" "$base") ]] || continue
    seen_base[$base]=1
    clips+=("$(basename "$poster")")
  done
  unset seen_base
  if (( ${#clips[@]} > 0 )); then
    # one clip per line — never space-join: clip names may contain spaces
    theme_clips["$t"]="$(printf '%s\n' "${clips[@]}" | sort)"
  fi
done

(( ${#theme_clips[@]} > 0 )) || {
  echo "error: no videos found in $USER_THEMES." >&2
  echo "       a video theme needs backgrounds/ posters with paired clips in backgrounds/." >&2
  exit 1
}

# --- dedupe: a per-clip theme (.video-theme marker) claims its clip; other
#     themes drop the same clip so the cycle never visits it twice ----------
declare -A claimed=()
declare -A marked=()
for tdir in "$USER_THEMES"/*/; do
  [[ -f "${tdir}.video-theme" ]] || continue
  t="${tdir%/}"; t="${t##*/}"
  marked["$t"]=1
  [[ -n ${theme_clips[$t]:-} ]] || continue
  while IFS= read -r c; do
    [[ -n $c ]] && claimed["${c%.*}"]=1
  done <<<"${theme_clips[$t]}"
done
for t in "${!theme_clips[@]}"; do
  [[ -n ${marked[$t]:-} ]] && continue
  keep=()
  while IFS= read -r c; do
    [[ -n $c ]] || continue
    [[ -n ${claimed["${c%.*}"]:-} ]] && continue
    keep+=("$c")
  done <<<"${theme_clips[$t]}"
  if (( ${#keep[@]} > 0 )); then
    theme_clips["$t"]="$(printf '%s\n' "${keep[@]}" | sort)"
  else
    unset "theme_clips[$t]"
  fi
done

(( ${#theme_clips[@]} > 0 )) || {
  echo "error: no videos found in $USER_THEMES." >&2
  exit 1
}

# --- theme order: cycle list first, the rest alphabetically -----------------
ordered=()
declare -A ordered_seen=()
if [[ -f $list ]]; then
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"   # ltrim
    line="${line%"${line##*[![:space:]]}"}"   # rtrim
    if [[ -n $line && -n ${theme_clips[$line]:-} && -z ${ordered_seen[$line]:-} ]]; then
      ordered+=("$line")
      ordered_seen["$line"]=1
    fi
  done <"$list"
fi
while IFS= read -r t; do
  if [[ -z ${ordered_seen[$t]:-} ]]; then
    ordered+=("$t")
    ordered_seen["$t"]=1
  fi
done < <(printf '%s\n' "${!theme_clips[@]}" | sort)

# --- flat entry list: "theme<TAB>poster" ------------------------------------
entries=()
for t in "${ordered[@]}"; do
  while IFS= read -r c; do
    [[ -n $c ]] && entries+=("$t"$'\t'"$c")
  done <<<"${theme_clips[$t]}"
done
n=${#entries[@]}

# --- find the currently playing video ---------------------------------------
idx=-1
for i in "${!entries[@]}"; do
  IFS=$'\t' read -r et ec <<<"${entries[$i]}"
  if [[ $et == "$CURRENT_THEME" && ( $ec == "$CUR_BASE" || $ec == "$CUR_BASE".* ) ]]; then
    idx=$i
    break
  fi
done

if [[ $direction == next ]]; then
  next_idx=$(( (idx + 1) % n ))
else
  next_idx=$(( (idx - 1 + n) % n ))
fi
if (( idx == -1 )); then
  next_idx=0
fi

# --- apply -------------------------------------------------------------------
IFS=$'\t' read -r t c <<<"${entries[$next_idx]}"
clip_base="${c%.*}"

if [[ $t != "$CURRENT_THEME" ]]; then
  if ! omarchy theme set "$t" >/dev/null 2>&1; then
    echo "error: omarchy theme set $t failed" >&2
    exit 1
  fi
  # The theme set may have started a backgrounds/intros/<stem> intro (native
  # Omarchy plumbing); loading the loop now would kill it — let it finish.
  "$(dirname "${BASH_SOURCE[0]}")/video-wait-intro.sh" || true
fi

# Point the background at the CLIP itself (the mp4). With the OWE backend the
# wallpaper daemon renders whatever the symlink names; the paired poster stays
# in backgrounds/ as its still partner (picker thumbnail, lock, battery poster).
# Only touch the background when it is not already the playing clip.
clip_video="$(paired_video "$HOME/.local/state/omarchy/current/theme" "$clip_base")"
if [[ -z $clip_video ]]; then
  # Defensive: the scan above guarantees a paired clip; fall back to poster.
  clip_video="$(find "$HOME/.local/state/omarchy/current/theme/backgrounds" \
    -maxdepth 1 -type f -name "$c" \
    ! -name '*.mp4' ! -name '*.mkv' ! -name '*.webm' ! -name '*.mov' ! -name '*.avi' \
    -print -quit 2>/dev/null || true)"
fi
staged_bg="$(readlink -f "$HOME/.local/state/omarchy/current/background" 2>/dev/null || true)"
if [[ ${staged_bg##*/} != "${clip_video##*/}" ]]; then
  omarchy theme bg set "$clip_video" >/dev/null 2>&1
fi

echo "video: $t / $clip_base"
