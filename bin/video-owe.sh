#!/usr/bin/env bash
# video-owe.sh — engine operations against the OWE wallpaper daemon (owed).
#
# The plugin no longer renders video itself: owed owns the wallpaper layer
# while the background symlink names a clip. This helper exposes the pieces
# of owed's CLI that matter to the library tools, in one place:
#
#   video-owe.sh has                    exit 0 while the daemon answers
#   video-owe.sh status                 human one-liner + detail lines
#   video-owe.sh pause | resume         manual pause
#   video-owe.sh animate on | off       force animation past auto-pauses
#   video-owe.sh battery play|pause|poster
#                                       write [pause] battery_mode in
#                                       ~/.config/owe/config.toml and reload
#
# All commands are best-effort and never fail the caller hard: the TUI shows
# whatever comes back.

set -euo pipefail

OWE_EXTENSIONS=(mp4 mkv webm mov avi)

paired_video() { # <theme-dir> <base> → clip path or empty
  local d=$1 b=$2 e
  for e in "${OWE_EXTENSIONS[@]}"; do
    [[ -f "$d/videos/$b.$e" ]] && { printf '%s' "$d/videos/$b.$e"; return 0; }
  done
  return 0
}

case "${1:-status}" in
  has)
    command -v owe >/dev/null 2>&1 || exit 1
    timeout 3 owe status >/dev/null 2>&1 || exit 1
    ;;

  status)
    s=$(timeout 5 owe status 2>/dev/null) || { echo "engine: owe no está respondiendo"; exit 1; }
    st=$(printf '%s' "$s" | jq -r '[.engine, .loaded_kind, (.loaded_path|split("/")|last),
            (.paused|tostring), .reason, (.always_animate|tostring),
            (.manual_pause|tostring), (.idle_pause|tostring), (.locked|tostring),
            (.on_battery|tostring), (.fullscreen|tostring), (.media_ready|tostring)] | @tsv' 2>/dev/null)
    IFS=$'\t' read -r engine kind loaded paused reason anim manual idle locked batt full ready <<<"$st"
    echo "engine: $engine · $kind: ${loaded:-none} · media_ready: $ready"
    flags=""
    [[ $paused == true ]] && flags="PAUSED ($reason)" || flags="playing ($reason)"
    [[ $manual == true ]] && flags="$flags · manual"
    [[ $idle == true ]] && flags="$flags · idle"
    [[ $locked == true ]] && flags="$flags · locked"
    [[ $full == true ]] && flags="$flags · fullscreen"
    [[ $batt == true ]] && flags="$flags · battery"
    [[ $anim == true ]] && flags="$flags · always-animate"
    echo "state: $flags"
    r=$(timeout 5 owe render-status 2>/dev/null | jq -r '[.hwdec, (.swaps|tostring), .error] | @tsv' 2>/dev/null || true)
    [[ -n $r ]] && { IFS=$'\t' read -r hwdec swaps error <<<"$r"; echo "decode: $hwdec · swaps: $swaps · error: ${error:-none}"; }
    ;;

  pause | resume | refresh)
    timeout 5 owe "$1" >/dev/null
    echo "ok: $1"
    ;;

  animate)
    case "${2:-}" in on|off) : ;; *) echo "usage: video-owe.sh animate on|off" >&2; exit 2 ;; esac
    timeout 5 owe always-animate "$2" >/dev/null
    echo "ok: always-animate $2"
    ;;

  battery)
    case "${2:-}" in play|pause|poster) mode="$2" ;; *)
      echo "usage: video-owe.sh battery play|pause|poster" >&2; exit 2 ;; esac
    cfg="${XDG_CONFIG_HOME:-$HOME/.config}/owe/config.toml"
    mkdir -p "$(dirname "$cfg")"
    tmp=$(mktemp)
    # Drop any previous battery keys, then (re)write battery_mode under [pause].
    grep -vE '^[[:space:]]*battery_(mode|poster)[[:space:]]*=' "$cfg" 2>/dev/null > "$tmp" || true
    if grep -qE '^\[pause\]' "$tmp"; then
      awk -v mode="$mode" '
        { print }
        !done && /^\[pause\]/ { print "battery_mode = \"" mode "\""; done=1 }
      ' "$tmp" > "$tmp.2"
    else
      { printf '\n[pause]\nbattery_mode = "%s"\n' "$mode"; cat "$tmp"; } > "$tmp.2"
    fi
    mv "$tmp.2" "$cfg"
    rm -f "$tmp"
    timeout 5 owe reload-config >/dev/null 2>&1 || true
    echo "ok: battery_mode = $mode ($cfg)"
    ;;

  intro)
    case "${2:-}" in on|off) : ;; *) echo "usage: video-owe.sh intro on|off" >&2; exit 2 ;; esac
    omarchy theme bg intro "$2" >/dev/null 2>&1 || true
    echo "ok: background intros $2"
    ;;

  extensions)
    printf '%s\n' "${OWE_EXTENSIONS[@]}"
    ;;

  *)
    echo "usage: video-owe.sh has|status|pause|resume|animate on|off|battery play|pause|poster" >&2
    exit 2
    ;;
esac
