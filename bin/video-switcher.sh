#!/bin/bash
# io.github.p3lu.video-background: carousel selector for the whole video library.
#
# Same UI as Omarchy's wallpaper switcher (a wrapper around
# omarchy-menu-images). The library is stable: it lists every clip of every
# user theme that has videos (a background poster with a paired video in
# videos/), so the list does not change when you cycle themes.
#
# Entry naming:
#   - the active theme's clips appear by clip name (e.g. 07-rebecca-gun);
#   - a theme with a single clip appears by theme name
#     (e.g. video-02-aurora-spruce-woods);
#   - other themes' clips are prefixed with the theme name
#     (e.g. video-wallpaper-01-city-night-ljubljana), so the same clip in
#     two themes stays two distinct entries.
#
# Selecting an entry:
#   - a clip of the active theme: `omarchy theme bg set` (video changes,
#     palette stays);
#   - a clip of another theme: `omarchy theme set` + `omarchy theme bg set`
#     (video and palette change together).
# The currently playing video is preselected.

set -euo pipefail

PLUGIN_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Self-deploy the keybindings (idempotent, silent, no reload if unchanged).
"$PLUGIN_BIN/video-bindings.sh" --add --quiet || true
# Reap abandoned per-clip themes (silent no-op when nothing to clean).
"$PLUGIN_BIN/video-cleanup.sh" || true
# Keep the theme menu clean (idempotent, silent).
"$PLUGIN_BIN/video-menu.sh" --add --quiet || true

USER_THEMES="$HOME/.config/omarchy/themes"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/video-switcher"
ENTRIES_TSV="$CACHE_DIR/entries.tsv"
CURRENT_THEME="$(cat "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null || true)"
CURRENT_THEME_PATH="$HOME/.local/state/omarchy/current/theme"
CURRENT_BACKGROUND="$(readlink -f "$HOME/.local/state/omarchy/current/background" 2>/dev/null || true)"
CUR_BASE=""
if [[ -n $CURRENT_BACKGROUND ]]; then
  CUR_BASE="${CURRENT_BACKGROUND##*/}"
  CUR_BASE="${CUR_BASE%.*}"
fi

# --- scan the library: themes that have at least one clip ------------------
declare -A theme_clips=()
for tdir in "$USER_THEMES"/*/; do
  [[ -d $tdir ]] || continue
  [[ -d "$tdir/backgrounds" && -d "$tdir/videos" ]] || continue
  t="${tdir%/}"; t="${t##*/}"
  clips=()
  for poster in "$tdir"/backgrounds/*; do
    [[ -f $poster ]] || continue
    base="${poster##*/}"; base="${base%.*}"
    [[ -f "$tdir/videos/$base.mp4" ]] || continue
    clips+=("$(basename "$poster")")
  done
  if (( ${#clips[@]} > 0 )); then
    theme_clips["$t"]="${clips[*]}"
  fi
done

(( ${#theme_clips[@]} > 0 )) || exit 0

# --- dedupe: a per-clip theme (.video-theme marker) claims its clip; other
#     themes drop the same clip so the carousel never lists it twice --------
declare -A claimed=()
declare -A marked=()
for tdir in "$USER_THEMES"/*/; do
  [[ -f "${tdir}.video-theme" ]] || continue
  t="${tdir%/}"; t="${t##*/}"
  marked["$t"]=1
  for c in ${theme_clips[$t]:-}; do
    claimed["${c%.*}"]=1
  done
done
for t in "${!theme_clips[@]}"; do
  [[ -n ${marked[$t]:-} ]] && continue
  keep=()
  for c in ${theme_clips[$t]}; do
    [[ -n ${claimed["${c%.*}"]:-} ]] && continue
    keep+=("$c")
  done
  if (( ${#keep[@]} > 0 )); then
    theme_clips["$t"]="${keep[*]}"
  else
    unset "theme_clips[$t]"
  fi
done

(( ${#theme_clips[@]} > 0 )) || exit 0

# Active theme first, the rest alphabetically.
ordered=()
if [[ -n $CURRENT_THEME && -n ${theme_clips[$CURRENT_THEME]:-} ]]; then
  ordered+=("$CURRENT_THEME")
fi
rest=()
for t in "${!theme_clips[@]}"; do
  [[ $t == "$CURRENT_THEME" ]] && continue
  rest+=("$t")
done
if (( ${#rest[@]} > 0 )); then
  mapfile -t rest < <(printf '%s\n' "${rest[@]}" | sort)
fi
ordered+=("${rest[@]}")

# --- build the carousel (one symlink per entry) + the dispatch table -------
rm -rf "$CACHE_DIR"
mkdir -p "$CACHE_DIR"
: >"$ENTRIES_TSV"

for t in "${ordered[@]}"; do
  tdir="$USER_THEMES/$t"
  read -ra clips <<<"${theme_clips[$t]}"
  for c in "${clips[@]}"; do
    if [[ $t == "$CURRENT_THEME" ]]; then
      entry="$c"
    elif (( ${#clips[@]} == 1 )); then
      entry="$t.${c##*.}"
    else
      entry="$t-$c"
    fi
    ln -s "$tdir/backgrounds/$c" "$CACHE_DIR/$entry"
    printf '%s\t%s\t%s\n' "${entry%.*}" "$t" "$c" >>"$ENTRIES_TSV"
  done
done

(( $(find "$CACHE_DIR" -type l | wc -l) > 0 )) || exit 0

# --- preselect the currently playing video ---------------------------------
selected_flag=()
if [[ -n $CUR_BASE || -n $CURRENT_THEME ]]; then
  for f in "$CACHE_DIR/$CUR_BASE".* "$CACHE_DIR/$CURRENT_THEME".*; do
    if [[ -e $f ]]; then
      selected_flag=(--selected "$f")
      break
    fi
  done
fi

name=$(omarchy-menu-images --print-name ${selected_flag[@]+"${selected_flag[@]}"} "$CACHE_DIR" || true)
[[ -n ${name:-} ]] || exit 0

# --- dispatch via the table (no name parsing) -------------------------------
row=$(awk -F'\t' -v n="$name" '$1 == n { print; exit }' "$ENTRIES_TSV")
[[ -n $row ]] || exit 0
IFS=$'\t' read -r _ entry_theme entry_poster <<<"$row"

# Nothing to do when the selection is already the playing video.
if [[ $entry_theme == "$CURRENT_THEME" && $CUR_BASE == "${entry_poster%.*}" ]]; then
  exit 0
fi

if [[ $entry_theme != "$CURRENT_THEME" ]]; then
  omarchy theme set "$entry_theme"
fi
omarchy theme bg set "$CURRENT_THEME_PATH/backgrounds/$entry_poster"
