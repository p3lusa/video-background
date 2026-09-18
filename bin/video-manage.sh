#!/usr/bin/env bash
# video-manage — video library manager (TUI).
#
# Stack (Charm best practice for shell TUIs, zero extra deps on an
# Omarchy system):
#   fzf  — list engine: fuzzy filter, preview pane, themed border,
#          custom keys, hero header + persistent footer
#   gum  — modals: file picker, confirm, spinner (themed by the active
#          palette via GUM_* env vars)
#
# Layout (variant A — "hero header"):
#   ┌ ▸ NOW PLAYING · <clip that is playing now> ┐   (fzf --header)
#   │  === LIBRARY (n)  <rich, aligned rows>      │   (fzf sections)
#   │  === ACTIONS    add / remove / help         │
#   ├ filter prompt ────────────────────────────────
#   │ footer: key hints + last-action feedback    │   (fzf --footer)
#   preview pane (right 1/3): poster thumbnail (kitty protocol, or
#   chafa→sixel when chafa is installed) + metadata card + action hints.
#
# Keys: Enter play · r remove · a add · h/? help · q/Esc quit
set -euo pipefail

# ---------------------------------------------------------------- paths ----
PLUGIN_BIN="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
THEMES_USER="$HOME/.config/omarchy/themes"
THEMES_SYS="${OMARCHY_PATH:-/usr/share/omarchy}/themes"
STAGED_BG_LINK="$HOME/.local/state/omarchy/current/background"
LIB_THEME="video-wallpaper"
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/video-manage"
META_DIR="$CACHE_ROOT/meta"
mkdir -p "$META_DIR"
SESSION="$(mktemp -d "$CACHE_ROOT/session.XXXXXX")"
trap 'rm -rf "$SESSION"' EXIT

# --------------------------------------------------------------- helpers ----
# col <hex> <text> — truecolor SGR (hex may include #)
col() { local h=${1##'#'}; shift
  [[ ${#h} -eq 6 ]] || { printf '%s' "$*"; return; }
  printf '\033[38;2;%d;%d;%dm%s\033[0m' \
    $((16#${h:0:2})) $((16#${h:2:2})) $((16#${h:4:2})) "$*"
}
# strip ANSI escapes from stdin
strip_ansi() { sed -e 's/\x1b\[[0-9;]*[mM]//g'; }
# pad <width> <text> — right-pad with spaces (visual width ≈ char count)
pad() { local w=$1 t=$2; printf '%-*s' "$w" "$t"; }
export -f col strip_ansi pad

# Palette of the *currently staged* theme. Re-read every loop iteration so
# the TUI re-themes itself when a per-clip palette is applied.
load_palette() {
  local cf="$HOME/.local/state/omarchy/current/theme/colors.toml"
  ACC="#5FB3FF" TXT="#E4E4E4" BG="#1C1E26" MUT="#959DA5"
  [[ -f $cf ]] || return 0
  local v
  v=$(sed -n 's/^accent[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$cf" | head -1)
  [[ -n $v ]] && ACC="$v"
  v=$(sed -n 's/^foreground[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$cf" | head -1)
  [[ -n $v ]] && TXT="$v"
  v=$(sed -n 's/^background[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$cf" | head -1)
  [[ -n $v ]] && BG="$v"
  v=$(sed -n 's/^color8[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$cf" | head -1)
  [[ -n $v ]] && MUT="$v"
  export ACC TXT BG MUT
}

# Icons: Nerd Font codepoints when the system has a Nerd Font (Omarchy's
# default), ASCII fallback otherwise.
declare_icons() {
  # no grep -q: pipefail + SIGPIPE would make the condition fail
  if command -v fc-list >/dev/null 2>&1 && [[ -n $(fc-list 2>/dev/null | grep -i nerd) ]]; then
    I_ADD=$'\uf067' I_RM=$'\uf1f8' I_HELP=$'\uf059' I_DOT=$'\uf111'
    I_FILM=$'\uf008'
  else
    I_ADD='+' I_RM='x' I_HELP='?' I_DOT='*' I_FILM='>'
  fi
  export I_ADD I_RM I_HELP I_DOT I_FILM
}

# ---------------------------------------------------------------- library ----
# $SESSION/library.tsv: name \t theme \t file \t kind(own|lib)
# Dedup: per-clip themes (with .video-theme marker) claim their clips;
# library themes drop clips already claimed.
# Note: supports both old structure (videos/ dir) and legacy (mp4 in backgrounds/)
scan_library() {
  local tmp="$SESSION/scan.tmp"
  : > "$tmp"
  local t b perclip f base
  local -A claimed=()
  for t in "$THEMES_USER"/* "$THEMES_SYS"/*; do
    # Must have backgrounds dir; videos dir is optional (legacy themes may use backgrounds/)
    [[ -d $t && -d $t/backgrounds ]] || continue
    b=$(basename "$t")
    perclip=0
    [[ -f $t/.video-theme ]] && perclip=1
    
    # Scan videos/ directory first (new structure)
    if [[ -d $t/videos ]]; then
      for f in "$t"/videos/*.mp4; do
        [[ -e $f ]] || continue
        base=$(basename "$f" .mp4)
        if [[ $perclip == 1 ]]; then
          printf '%s\t%s\t%s\t%s\n' "$base" "$b" "$f" own >> "$tmp"
          claimed["$base"]=1
        elif [[ -z ${claimed["$base"]:-} ]]; then
          printf '%s\t%s\t%s\t%s\n' "$base" "$b" "$f" lib >> "$tmp"
        fi
      done
    fi
    
    # Also scan backgrounds/ for mp4 files (legacy structure for themes like event-horizon)
    # Skip if already claimed by videos/ scan
    for f in "$t"/backgrounds/*.mp4; do
      [[ -e $f ]] || continue
      base=$(basename "$f" .mp4)
      [[ -z ${claimed["$base"]:-} ]] || continue
      if [[ $perclip == 1 ]]; then
        printf '%s\t%s\t%s\t%s\n' "$base" "$b" "$f" own >> "$tmp"
        claimed["$base"]=1
      elif [[ -z ${claimed["$base"]:-} ]]; then
        printf '%s\t%s\t%s\t%s\n' "$base" "$b" "$f" lib >> "$tmp"
      fi
    done
  done
  local tab; tab=$(printf '\t')
  sort -t"$tab" -k1,1 -o "$SESSION/library.tsv" "$tmp"
  rm -f "$tmp"
}

current_state() {
  # same sources of truth as video-cycle.sh
  CUR_THEME=$(tr -d '[:space:]' < "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null) || CUR_THEME=""
  CUR_THEME=${CUR_THEME:-?}
  CUR_BASE=""
  local bg
  bg=$(readlink -f "$STAGED_BG_LINK" 2>/dev/null) || bg=""
  if [[ -n $bg ]]; then
    CUR_BASE="${bg##*/}"
    CUR_BASE="${CUR_BASE%.*}"
  fi
  export CUR_THEME CUR_BASE
}

# ffprobe metadata, cached per clip (invalidated by mtime).
clip_meta() { # <file> → "20s · 1920x1080@30fps · 12.3 MB"
  local file=$1
  local m="$META_DIR/$(basename "$file" .mp4).meta"
  if [[ ! -f $m || $file -nt $m ]]; then
    local out w h rate dur size fps dur_s size_mb
    out=$(ffprobe -v error -select_streams v:0 \
      -show_entries stream=width,height,avg_frame_rate:format=duration,size \
      -of csv=p=0 "$file" 2>/dev/null) || out=""
    out=${out//$'\n'/,}
    IFS=',' read -r w h rate dur size <<<"$out"
    fps=${rate%%/*}
    dur_s=${dur%%.*}
    size_mb=$(awk -v s="${size:-0}" 'BEGIN{printf "%.1f", s/1048576}')
    printf '%ss · %sx%s@%sfps · %s MB\n' \
      "${dur_s:-?}" "${w:-?}" "${h:-?}" "${fps:-?}" "${size_mb:-?}" > "$m"
  fi
  cat "$m" 2>/dev/null || true
}
export -f clip_meta
export META_DIR

# ------------------------------------------------------------- list/preview ----
# Row layout:  MARK NAME<24> TAG<12> META
#   MARK = ●  (playing) or two spaces
# MARKW=2  NAMEW=24  TAGW=12
readonly MARKW=2 NAMEW=24 TAGW=12

# line_to_name — strip MARK + trailing tag/meta → bare clip name.
# fzf already returns the plain (ANSI-stripped) line, but strip again for
# safety; then drop the leading 2-char mark, trim, and cut at the tag.
line_to_name() {
  local p
  p=$(strip_ansi <<<"$1")
  p=${p:2}                       # drop MARK ("● " or "  ")
  p="${p#"${p%%[![:space:]]*}"}" # ltrim
  p=${p%%[[:space:]]\[*}         # cut at the " [tag]"/meta boundary
  p="${p%"${p##*[![:space:]]}"}" # rtrim
  printf '%s' "$p"
}
export -f line_to_name
export SESSION

tag_for() { [[ $1 == own ]] && echo "own palette" || echo "library"; }

# poster path for a clip (name → theme dir → backgrounds/<base>.png|jpg|..)
poster_for() { # <name> → path or ""
  local name=$1 row base theme f kind tdir c
  row=$(grep -P "^\Q${name}\E	" "$SESSION/library.tsv" 2>/dev/null | head -1) || true
  [[ -z $row ]] && return 0
  # columns: name 	 theme 	 file 	 kind
  IFS=$'	' read -r base theme f kind <<<"$row"
  # derive the theme dir from the video file path: .../<theme>/videos/<base>.mp4
  tdir=$(dirname "$(dirname "$f")")
  for c in "$tdir/backgrounds/$base.png" "$tdir/backgrounds/$base.jpg" \
           "$tdir/backgrounds/$base.jpeg" "$tdir/backgrounds/$base.webp"; do
    [[ -f $c ]] && { printf '%s' "$c"; return 0; }
  done
  return 0
}
export -f poster_for

# Detect image protocol once: kitty (zero-dep), else chafa→sixel, else none.
detect_img_proto() {
  if [[ -n ${KITTY_WINDOW_ID:-} ]]; then
    IMG_PROTO=kitty
  elif command -v chafa >/dev/null 2>&1; then
    IMG_PROTO=sixel
  else
    IMG_PROTO=none
  fi
  export IMG_PROTO
}

# Render the poster for a clip into the preview pane (stdout). No-op to the
# text card when there is no image protocol or no poster. Output is cached in
# $SESSION/poster-<base>-<w>.img and regenerated only when the poster or the
# target width changes.
render_poster() { # <name>
  local name=$1 p cache w cols c iw ih rows i
  p=$(poster_for "$name")
  # The preview pane must always show *this* clip's image. kitty keeps image
  # placements alive across preview redraws, so if this clip has no poster
  # the previous clip's picture would linger — clear all placements first,
  # even in the no-poster case.
  [[ -z $IMG_PROTO || $IMG_PROTO == kitty ]] && printf '\033_Ga=d\033\\'
  [[ -z $p || -z $IMG_PROTO || $IMG_PROTO == none ]] && return 0
  # Dynamic target: the preview pane is fzf's right 33%. Recomputed on every
  # render (fzf re-runs the preview on focus/resize/redraw) so the poster
  # follows the terminal size. `c` is the pane width in COLUMNS; `w` is the
  # source pixel width we ask ffmpeg for (~8 px per monospace cell).
  cols=$(tput cols 2>/dev/null) || cols=80
  (( cols < 40 )) && cols=40
  c=$(( cols / 3 - 2 )); (( c < 12 )) && c=12   # minus the preview border
  w=$(( c * 8 )); (( w > 720 )) && w=720
  # Rows the image occupies when displayed `c` columns wide, from the poster's
  # own aspect ratio (ih/iw). Drives both the kitty placement box (a=p,c,r)
  # and the newline padding, so the text card always starts exactly below the
  # image — no pixel/cell conversion needed.
  rows=0
  # ffprobe csv is "W,H" — split on the comma (read's default IFS is
  # whitespace, which would leave ih empty).
  IFS=',' read -r iw ih < <(ffprobe -v error -select_streams v:0 \
      -show_entries stream=width,height -of csv=p=0 "$p" 2>/dev/null) || true
  iw=${iw:-0}; ih=${ih:-0}
  if (( iw > 0 && ih > 0 )); then
    rows=$(( (c * ih + iw / 2) / iw )); (( rows < 1 )) && rows=1
  fi
  # basename removes the directory; strip any image extension to get a clean
  # cache key (remove everything from the first dot).
  cache="$SESSION/poster-$(basename "$p" | sed 's/\.[^.]*$//')-$w.img"
  if [[ ! -f $cache || $p -nt $cache ]]; then
    local out=""
    case $IMG_PROTO in
      kitty)
        # downscale with ffmpeg (always present) -> PNG -> chunked kitty
        # transmit. The spec (sw.kovidgoyal.net/kitty/graphics-protocol)
        # requires the base64 payload in frames (`m=1` per chunk, `m=0` on the
        # last, each chunk <= 4 KB) because a single multi-megabyte APC is
        # dropped by kitty intermittently. We cache only the TRANSMIT (image
        # bytes); the display placement + row padding are emitted fresh below
        # so they always match the current pane size.
        local tmp="$SESSION/thumb.png"
        if ffmpeg -v error -y -i "$p" -vf "scale=${w}:-2" "$tmp" 2>/dev/null; then
          local first=1 chunk
          {
            while IFS= read -r chunk; do
              if [[ $first -eq 1 ]]; then
                printf '\033_Ga=T,f=100,m=1;%s\033\\' "$chunk"; first=0
              else
                printf '\033_Gm=1;%s\033\\' "$chunk"
              fi
            done < <(base64 -w 4096 "$tmp")
            if [[ $first -eq 1 ]]; then
              printf '\033_Ga=T,f=100,m=0;\033\\'   # empty image edge case
            else
              printf '\033_Gm=0;\033\\'              # final (empty) chunk
            fi
          } > "$cache"
          out="$cache"
        fi
        ;;
      sixel)
        out=$(chafa --format sixel --width "$c" -- "$p" 2>/dev/null) || out=""
        if [[ -n $out ]]; then
          printf '%s' "$out" > "$cache"
        else
          rm -f "$cache"; return 0
        fi
        ;;
    esac
    [[ -z $out ]] && return 0
  fi
  # Emit the image, then (kitty) the display placement, then enough newlines
  # to push the text card below the picture. fzf's preview pane does not
  # reserve rows for a kitty image, so without this padding the metadata card
  # renders on top of it. sixel advances the cursor on its own — keep the
  # original single newline there.
  cat "$cache"
  if [[ $IMG_PROTO == kitty ]]; then
    if (( rows > 0 )); then
      printf '\033_Ga=p,c=%s,r=%s\033\\' "$c" "$rows"
      for ((i=0;i<rows;i++)); do printf '\n'; done
    fi
  else
    printf '\n'
  fi
}
export -f render_poster

# build a rich, aligned clip row.
render_clip() { # <name> <theme> <file> <kind>
  local name=$1 theme=$2 file=$3 kind=$4 tag mark meta
  tag=$(tag_for "$kind")
  meta=$(clip_meta "$file")
  if [[ $name == "$CUR_BASE" && $theme == "$CUR_THEME" ]]; then
    mark=$(col "$ACC" "● ")
    printf '%s %s %s %s\n' \
      "$mark" "$(col "$ACC" "$(pad "$NAMEW" "$name")")" \
      "$(col "$ACC" "$(pad "$TAGW" "[$tag]")")" \
      "$(col "$MUT" "$meta")"
  else
    mark="  "
    printf '%s %s %s %s\n' \
      "$mark" "$(col "$TXT" "$(pad "$NAMEW" "$name")")" \
      "$(col "$MUT" "$(pad "$TAGW" "[$tag]")")" \
      "$(col "$MUT" "$meta")"
  fi
}
export -f render_clip tag_for

# row_file <name> → video path (for meta lookup)
row_file() {
  local row
  row=$(grep -P "^\Q${1}\E\t" "$SESSION/library.tsv" 2>/dev/null | head -1) || true
  [[ -z $row ]] && return 0
  IFS=$'	' read -r _ _ f _ <<<"$row"
  printf '%s' "$f"
}
export -f row_file

# section header line (fzf treats a leading "=== " as a section divider)
section_hdr() { # <text>
  printf '=== %s\n' "$(col "$MUT" "$1")"
}
export -f section_hdr

build_list() {
  local name theme file kind n
  n=$(wc -l < "$SESSION/library.tsv")
  section_hdr "LIBRARY ($n)"
  while IFS=$'	' read -r name theme file kind; do
    render_clip "$name" "$theme" "$file" "$kind"
  done < "$SESSION/library.tsv"
  section_hdr "ACTIONS"
  printf '%s\n' "$(col "$ACC" "$I_ADD  ")$(col "$TXT" "Add a video (a key)")"
  printf '%s\n' "$(col "$ACC" "$I_RM   ")$(col "$TXT" "Remove a video (r key)")"
  printf '%s\n' "$(col "$ACC" "$I_HELP ")$(col "$TXT" "How to use (h key)")"
}

build_clips_only() {
  local name theme file kind
  while IFS=$'	' read -r name theme file kind; do
    render_clip "$name" "$theme" "$file" "$kind"
  done < "$SESSION/library.tsv"
}

# hero header (fzf --header): the clip that is playing right now.
build_hero() {
  local line1 line2
  line1="$(col "$ACC" "▸ NOW PLAYING")"
  if [[ -n $CUR_BASE && $CUR_BASE != "?" ]]; then
    local row meta
    row=$(grep -P "^\Q${CUR_BASE}\E\t" "$SESSION/library.tsv" 2>/dev/null | head -1) || true
    if [[ -n $row ]]; then
      IFS=$'	' read -r _ _ f kind <<<"$row"
      meta=$(clip_meta "$f")
      line2="$(col "$ACC" "  ● ")$(col "$TXT" "$(pad 26 "$CUR_BASE")")$(col "$MUT" "  $(tag_for "$kind")  $meta")"
    else
      line2="$(col "$ACC" "  ● ")$(col "$TXT" "$CUR_BASE")$(col "$MUT" "  theme: $CUR_THEME")"
    fi
  else
    line2="$(col "$MUT" "  (none) · $n clips in library")"
  fi
  printf '%s\n%s' "$line1" "$line2"
}
export -f build_hero

# footer (fzf --footer): one line — key hints, with last-action feedback
# prepended when present.
build_footer() {
  local hints
  hints="$(col "$MUT" "a") $(col "$TXT" "add") · $(col "$MUT" "r") $(col "$TXT" "remove") · $(col "$MUT" "enter") $(col "$TXT" "play") · $(col "$MUT" "h") $(col "$TXT" "help") · $(col "$MUT" "q") $(col "$TXT" "quit")"
  if [[ -n ${FEEDBACK:-} ]]; then
    printf '%s   %s' "$(col "$ACC" "$FEEDBACK")" "$hints"
  else
    printf '%s' "$hints"
  fi
}
export -f build_footer

# preview pane (right 1/3): poster + metadata card + action hints.
preview_cmd() {
  local line plain name row theme file kind status rule
  line=$1
  plain=$(strip_ansi <<<"$line")
  printf '%s' "$plain" > "$SESSION/hl"
  rule="────────────────────────────────────────"
  case $plain in
    *"Add a video"*)
      printf '%s\n' "Add a video" "$rule" "" \
        "Pick a clip (mp4/mov/webm). If it carries an audio track" \
        "you are asked to drop it (lossless remux — the plugin has" \
        "no volume control). Its palette is then extracted with" \
        "Aether, a per-clip theme is created, and the clip is" \
        "mirrored into the library theme (hardlinks — zero extra" \
        "space). Adding never changes the current wallpaper —" \
        "press Enter on the clip to play it." "" \
        "Tip: rename the file before adding; the clip and its" \
        "theme are named after the file."
      return ;;
    *"Remove a video"*)
      printf '%s\n' "Remove a video" "$rule" "" \
        "Select the video to remove from the library." "" \
        "Deletes its per-clip theme, every library copy, and its" \
        "cycle-list entry. If it is the playing one, another" \
        "video takes over first. Your original clip file is" \
        "never touched."
      return ;;
    *"How to use"*)
      printf '%s\n' "Keys" "$rule" "" \
        "  Enter   play (video + palette)" \
        "  r       remove a video (picker)" \
        "  a       add a video (file picker)" \
        "  h       help (full instructions)" \
        "  q/Esc   quit" "" \
        "  up/down or j/k  move · type to filter"
      return ;;
  esac
  # section divider line → show nothing
  [[ $plain == "==="* ]] && return 0
  name=$(line_to_name "$plain")
  row=$(grep -P "^\Q${name}\E\t" "$SESSION/library.tsv" 2>/dev/null | head -1) || true
  if [[ -z $row ]]; then
    printf 'unknown: %s\n' "$name"; return
  fi
  IFS=$'	' read -r name theme file kind <<<"$row"
  status="idle"
  [[ $name == "$CUR_BASE" && $theme == "$CUR_THEME" ]] && status="PLAYING"
  # poster (image) when the terminal can show it
  render_poster "$name"
  printf '%s\n' "" "$name" "$rule" "" \
    "theme     $theme" \
    "kind      $(tag_for "$kind")" \
    "status    $(col "$ACC" "$status")" \
    "media     $(clip_meta "$file")" \
    "" \
    "$(col "$MUT" "Enter → play · r → remove")"
}
export -f preview_cmd

# ---------------------------------------------------------------- security ----
# validate_video_path <path> — shared security gate for the add flow.
# Resolves the path (following symlinks) and accepts it only when ALL hold:
#   1. it exists and is a regular file
#   2. the RESOLVED path is inside $HOME (catches symlink escapes: a link to
#      /etc/hostname resolves outside home and is rejected)
#   3. it is not under a sensitive directory (~/.ssh, ~/.gnupg,
#      ~/.password-store, the omarchy config/state/cache trees — touching
#      those while "adding a video" would corrupt plugin state)
#   4. its extension is a supported video format (case-insensitive)
# On success: prints the resolved absolute path, returns 0.
# On failure: prints a human-readable REASON to the global $REJECT_REASON,
# returns 1.
validate_video_path() { # <path>
  local f=$1 resolved
  resolved=$(realpath -e -- "$f" 2>/dev/null) || { REJECT_REASON="file does not exist"; return 1; }
  [[ -f $resolved ]] || { REJECT_REASON="not a regular file"; return 1; }
  case "$resolved" in
    "$HOME"/*) : ;;
    *) REJECT_REASON="outside your home directory"; return 1 ;;
  esac
  case "$resolved" in
    "$HOME"/.ssh/*|"$HOME"/.gnupg/*|"$HOME"/.password-store/*)
      REJECT_REASON="sensitive directory"; return 1 ;;
    "$HOME"/.config/omarchy/*|"$HOME"/.local/state/omarchy/*|"$HOME"/.cache/omarchy/*)
      REJECT_REASON="omarchy internal path"; return 1 ;;
  esac
  case "${resolved,,}" in
    *.mp4|*.mov|*.webm|*.mkv|*.avi) : ;;
    *) REJECT_REASON="not a video file (mp4, mov, webm, mkv, avi)"; return 1 ;;
  esac
  printf '%s' "$resolved"
  return 0
}
export -f validate_video_path

# dir_is_safe <dir> — like validate_video_path but for a directory the user
# is about to enter (same rules minus the file/extension checks).
dir_is_safe() { # <dir>
  local d=$1 resolved
  resolved=$(realpath -e -- "$d" 2>/dev/null) || return 1
  [[ -d $resolved ]] || return 1
  case "$resolved" in
    "$HOME") return 0 ;;
    "$HOME"/*) : ;;
    *) return 1 ;;
  esac
  case "$resolved" in
    "$HOME"/.ssh/*|"$HOME"/.gnupg/*|"$HOME"/.password-store/*|"$HOME"/.ssh|"$HOME"/.gnupg) return 1 ;;
    "$HOME"/.config/omarchy|"$HOME"/.config/omarchy/*|"$HOME"/.local/state/omarchy|"$HOME"/.local/state/omarchy/*) return 1 ;;
  esac
  return 0
}
export -f dir_is_safe

# ------------------------------------------------------------- actions ----
# video_browser <start-dir> — secure, filterable directory browser (fzf).
# Replaces `gum file`, which had neither text filtering nor real scrolling.
#   - lists sub-directories (enter with Enter) and video files only
#   - type to fuzzy-filter the current level (fzf native)
#   - scrolls (fzf native, any list length)
#   - ctrl-u = one level up (blocked at $HOME), ctrl-r = refresh
# Every directory the user enters and every file the user picks is
# re-validated (dir_is_safe / validate_video_path) — the list is only a UI.
# Prints the chosen file on success; returns 1 on cancel.
video_browser() { # <start-dir>
  local dir=$1 pick act
  dir_is_safe "$dir" || { REJECT_REASON="starting directory is not allowed"; return 1; }
  while true; do
    rm -f "$SESSION/bract"
    printf '%s' "$dir" > "$SESSION/brdir"   # for the preview pane
    pick=$(browser_list "$dir" | fzf \
        --height "60%" --border \
        --border-label " add video · $(basename -- "$dir") " --border-label-pos 3 \
        --prompt "filter: " \
        --ansi \
        --header "Enter dir → cd · Enter video → add · ctrl-u up · ctrl-r refresh · q cancel" \
        --preview 'browser_preview {}' \
        --preview-window "right:35%,border-rounded" \
        --bind "ctrl-u:execute-silent(echo UP > $SESSION/bract)+abort" \
        --bind "ctrl-r:execute-silent(echo REFRESH > $SESSION/bract)+abort+redraw" \
        --bind "q:abort,esc:abort" \
        --color "$(fzf_colors)" \
        2>/dev/null) || pick=""
    act=$(cat "$SESSION/bract" 2>/dev/null) || act=""
    rm -f "$SESSION/bract"
    if [[ -z $pick ]]; then
      case $act in
        UP)
          # go up, blocked at $HOME
          [[ $dir == "$HOME" ]] && return 1
          dir=$(dirname -- "$dir")
          continue ;;
        REFRESH) continue ;;   # re-list the same directory
        *) return 1 ;;          # esc/q → cancel
      esac
    fi
    if [[ $pick == */ ]]; then
      # a directory was chosen → validate, then descend
      if dir_is_safe "$dir/${pick%/}"; then
        dir="$dir/${pick%/}"
      else
        REJECT_REASON="directory not allowed: $pick"
        return 1
      fi
      continue
    fi
    # a file was chosen → final security gate, then hand back the resolved path
    if validate_video_path "$dir/$pick"; then
      return 0
    fi
    return 1
  done
}
export -f video_browser

# browser_list <dir> — one entry per line: "name/" for dirs, "name" for
# video files. Directories first, then videos, each sorted. Symlinked
# directories are listed (-xtype d) but only accepted if dir_is_safe passes.
browser_list() { # <dir>
  local dir=$1 d f
  while IFS= read -r d; do
    dir_is_safe "$d" || continue
    printf '%s/\n' "$(basename -- "$d")"
  done < <(find "$dir" -mindepth 1 -maxdepth 1 \( -type d -o -xtype d \) 2>/dev/null | sort)
  while IFS= read -r f; do
    printf '%s\n' "$(basename -- "$f")"
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f 2>/dev/null \
             | grep -iE '\.(mp4|mov|webm|mkv|avi)$' | sort)
  return 0
}
export -f browser_list

# browser_preview <line> — size + media info for a video, clip count for a dir.
browser_preview() { # <line>
  local line=$1 cur
  cur=$(cat "$SESSION/brdir" 2>/dev/null) || cur="$HOME"
  case $line in
    */)
      local n
      n=$(find "$cur/${line%/}" -mindepth 1 -maxdepth 1 -type f 2>/dev/null \
             | grep -ciE '\.(mp4|mov|webm|mkv|avi)$')
      printf '%s\n' "$(col "$ACC" "directory")  $n video file(s) · press Enter to open"
      ;;
    *)
      printf '%s\n' "$line"
      clip_meta "$cur/$line" 2>/dev/null || true
      ;;
  esac
}
export -f browser_preview

do_play() { # <name>
  local name=$1 row theme file
  row=$(grep -P "^\Q${name}\E\t" "$SESSION/library.tsv" 2>/dev/null | head -1) || true
  [[ -z $row ]] && return 1
  IFS=$'\t' read -r _ theme file _ <<<"$row"
  if [[ $theme == "$CUR_THEME" ]]; then
    omarchy theme bg set "$file"
  else
    omarchy theme set "$theme"
    omarchy theme bg set "$file"
  fi
  FEEDBACK="playing $name · $theme"
}

do_add() {
  # Secure directory navigation: start in Downloads (where the user's clips
  # live), fall back to Videos/, then $HOME. The browser validates every
  # step; validate_video_path is the final gate on the chosen file.
  local start="" d
  for d in "$HOME/Downloads" "$HOME/Videos" "$HOME"; do
    if [[ -d $d ]] && dir_is_safe "$d"; then start=$d; break; fi
  done
  if [[ -z $start ]]; then
    FEEDBACK="add: no usable start directory"
    return 0
  fi
  local f
  if ! f=$(video_browser "$start"); then
    [[ -n ${REJECT_REASON:-} ]] && FEEDBACK="add rejected: ${REJECT_REASON}"
    REJECT_REASON=""
    return 0
  fi
  [[ -z $f ]] && return 0

  local name=${f##*/}; name=${name%.*}
  # The plugin has no volume control: a clip with an audio track would be
  # heard. Offer to drop the track (lossless remux) before adding; if the
  # user declines, abort (the add would fail anyway).
  local strip=""
  if ffprobe -v error -select_streams a -show_entries stream=codec_type \
       "$f" 2>/dev/null | grep -q audio; then
    # gum 2.x confirm takes the prompt as a POSITIONAL arg (no --title /
    # --description flags — they exist in gum 1.x only and abort on 2.x).
    if gum confirm \
         "Drop the audio track?
'$name' carries audio; the plugin has no volume control and would play it.
Drop the track now (lossless remux)?" \
         --affirmative "Drop audio" --negative "Cancel"; then
      strip="--strip-audio"
    else
      FEEDBACK="aborted: $name has an audio track"
      return 0
    fi
  fi
  # --no-activate: adding must not yank the current wallpaper.
  if gum spin --spinner dot --title "creating theme (Aether + library mirror)" \
       --show-output -- "$PLUGIN_BIN/video-add.sh" $strip --no-activate "$f" 2>&1; then
    FEEDBACK="added $name"
  else
    FEEDBACK="add failed: $name"
  fi
}

do_remove() { # <name>
  local name=$1
  # gum 2.x confirm takes the prompt as a POSITIONAL arg (no --title /
  # --description flags — they exist in gum 1.x only and abort on 2.x).
  gum confirm \
    "Remove '$name'?
Deletes its per-clip theme, library copies and cycle entry. Your original clip file is untouched." \
    --affirmative "Remove" --negative "Cancel" || return 0
  if gum spin --spinner dot --title "removing $name" \
       --show-output -- "$PLUGIN_BIN/video-remove.sh" "$name" 2>&1; then
    FEEDBACK="removed $name"
  else
    FEEDBACK="remove failed: $name"
  fi
}

# Picker used both by the "Remove a video" entry and the 'r' key: lists only
# clips (with preview), the user chooses, then do_remove confirms.
remove_picker() {
  local pick
  pick=$(build_clips_only | fzf \
      --height "90%" --border --no-scrollbar \
      --border-label " select a video to remove " --border-label-pos 3 \
      --prompt "  " --ansi \
      --preview "preview_cmd {}" \
      --preview-window "right:33%,border-rounded" \
      --bind "q:abort" \
      --color "$(fzf_colors)" \
      2>/dev/null) || pick=""
  [[ -n $pick ]] && do_remove "$(line_to_name "$pick")"
}

show_help() {
  local text
  text=$(cat <<'EOF'
How to use
───────────────────────────────────────────────
  Navigate    up/down  ·  j/k  ·  type to filter
  Play        Enter on a clip — switches the video
              and the palette (per-clip themes)
  Remove      r, or the "Remove a video" entry —
              opens a picker to choose the clip
  Add         a, or the "Add a video" entry — file
              picker (starts in Downloads), then
              Aether extracts the palette and
              registers the clip
  Help        h or ?  ·   Quit  q / Esc

  [own palette]  the clip has its own theme; its
  colors were extracted from the clip (Aether)
  [library]      the clip plays in the library
  theme's palette

  Add: any video works (mp4/mov/webm/mkv/avi). If
  it has an audio track you are asked to drop it
  (the plugin has no volume control). Adding never
  changes the current wallpaper — Enter on the
  clip plays it. The clip is mirrored into the
  library theme with hardlinks (zero extra space).
  Remove: deletes the per-clip theme, library
  copies and the cycle-list entry. If the clip
  is the playing one, another video takes over
  first. Your original file is never touched.
EOF
)
  # Use the controlling terminal directly to work within fzf context
  local tty_dev
  tty_dev=$(tty 2>/dev/null) || tty_dev="/dev/tty"
  
  {
    clear
    printf '\n'
    if command -v gum >/dev/null 2>&1; then
      printf '%s\n' "$text" | gum style --border rounded --border-foreground "$ACC" \
        --margin "0 1" --padding "1 2" --width 64 2>/dev/null || printf '%s\n' "$text"
    else
      printf '%s\n' "$text"
    fi
    printf '\n'
    printf '  Press any key to go back…'
    read -r -s -n 1
    printf '\n'
  } <"$tty_dev" >"$tty_dev" 2>&1
}

# ------------------------------------------------------------------- main ----
fzf_colors() {
  printf 'fg:#%s,bg:#%s,fg+:#%s,header:#%s,info:#%s,query:#%s,pointer:#%s,marker:#%s,prompt:#%s,border:#%s' \
    "${TXT#'#'}" "${BG#'#'}" "${ACC#'#'}" "${ACC#'#'}" "${MUT#'#'}" "${ACC#'#'}" "${ACC#'#'}" "${ACC#'#'}" "${ACC#'#'}" "${ACC#'#'}"
}

main() {
  local FEEDBACK="" out rc action n
  detect_img_proto
  while true; do
    load_palette
    declare_icons
    scan_library
    current_state
    n=$(wc -l < "$SESSION/library.tsv")

    local label=" $I_FILM  video library · $n clips · theme: $CUR_THEME"

    rm -f "$SESSION/action"
    rc=0
    out=$(build_list | fzf \
        --height "90%" \
        --border \
        --border-label "$label" \
        --border-label-pos 3 \
        --prompt "filter: " \
        --ansi \
        --header "$(build_hero)" \
        --footer "$(build_footer)" \
        --preview "preview_cmd {}" \
        --preview-window "right:33%,border-rounded" \
        --bind "a:execute-silent(echo ADD > $SESSION/action)+abort" \
        --bind "r:execute-silent(echo REMOVE > $SESSION/action)+abort" \
        --bind "h:execute-silent(echo HELP > $SESSION/action)+abort" \
        --bind "?:execute-silent(echo HELP > $SESSION/action)+abort" \
        --bind "q:abort,esc:abort" \
        --color "$(fzf_colors)" \
        2>/dev/null) || rc=$?

    action=$(cat "$SESSION/action" 2>/dev/null) || action=""
    rm -f "$SESSION/action"

    # shortcut key (a/r/?) → abort with marker
    if [[ -n $action ]]; then
      FEEDBACK=""
      case $action in
        ADD) do_add ;;
        REMOVE) remove_picker ;;
        HELP) show_help ;;
      esac
      continue
    fi

    # Enter on an item → normal selection; else quit
    if [[ $rc -ne 0 || -z $out ]]; then
      break
    fi
    FEEDBACK=""

    local plain; plain=$(strip_ansi <<<"$out")
    case $plain in
      *"Add a video"*) do_add ;;
      *"Remove a video"*) remove_picker ;;
      *"How to use"*) show_help ;;
      "==="*) : ;;   # section divider selected → ignore
      *)
        do_play "$(line_to_name "$out")" || true
        ;;
    esac
  done
}

# Testability: with VM_NO_MAIN=1 the script only loads its functions (used
# by the unit tests); normally it runs the TUI.
if [[ -z ${VM_NO_MAIN:-} ]]; then
  main "$@"
fi
