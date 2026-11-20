#!/usr/bin/env bash
# test_thumbnail.sh — verify render_poster emits a *valid* kitty graphics
# sequence for the preview pane. The original bug: the poster "failed some of
# the time" because the base64 payload was sent as one giant APC, which kitty
# drops. The spec (sw.kovidgoyal.net/kitty/graphics-protocol) requires the
# payload split into chunks (m=1 per chunk, final m=0) and scaling done by a
# separate *placement* action (a=p), not by the transmit width.
#
# This test renders a real poster and asserts the emitted sequence is well
# formed: correct action verbs, chunked payload, exactly one final chunk,
# a placement that references the pane width, and no leftover data.
set -u
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
MANAGE="$SCRIPT_DIR/bin/video-manage.sh"
SANDBOX="$(mktemp -d)"
PASS=0 FAIL=0
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"
mkdir -p "$HOME" "$HOME/.cache/omarchy/video-manage/meta"

# fake a theme with a poster + clip so poster_for() resolves
THEME="$HOME/.config/omarchy/themes/video-test"
mkdir -p "$THEME/backgrounds" "$THEME/videos"
ffmpeg -v error -f lavfi -i "testsrc=size=1280x720:rate=10:duration=1" -y "$THEME/videos/test.mp4" 2>/dev/null
ffmpeg -v error -y -i "$THEME/videos/test.mp4" -frames:v 1 "$THEME/backgrounds/test.png"
touch "$THEME/.video-theme"

VM_NO_MAIN=1 . "$MANAGE"
IMG_PROTO=kitty
export SESSION="$SANDBOX/session"; mkdir -p "$SESSION"

# point the library at our clip
printf 'test\tvideo-test\t%s/videos/test.mp4\town\n' "$THEME" > "$SESSION/library.tsv"

ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }

out=$(render_poster "test" 2>/dev/null)

# 1) emitted something
[[ -n $out ]] && ok "render_poster emitted output" || bad "render_poster emitted output (empty)"

# 2) count the APC actions (\033_G ... \033\)
apcs=$(printf '%s' "$out" | grep -ao $'\033_G[^\\]*\033' | wc -l)
[[ $apcs -ge 2 ]] && ok "multiple APC actions emitted ($apcs)" || bad "multiple APC actions emitted (got $apcs)"

# 3) exactly one transmit (a=T) and it opens the image
trans=$(printf '%s' "$out" | grep -ao $'\033_Ga=T[^\\]*' | wc -l)
[[ $trans -eq 1 ]] && ok "exactly one transmit a=T" || bad "exactly one transmit a=T (got $trans)"

# 4) every data chunk is m=1 and the final one is m=0
m1=$(printf '%s' "$out" | grep -ao $'\033_Gm=1;' | wc -l)
m0=$(printf '%s' "$out" | grep -ao $'\033_Gm=0;' | wc -l)
[[ $m1 -ge 1 && $m0 -eq 1 ]] && ok "chunked payload: $m1 data chunks + 1 final (m=1…m=0)" || bad "chunked payload (m=1:$m1 m=0:$m0)"

# 5) the final m=0 must come AFTER the last m=1 (correct ordering)
last_m0=$(printf '%s' "$out" | grep -ao $'\033_Gm=0;' | tail -1 | wc -l)
first_m0_pos=$(printf '%s' "$out" | grep -abo $'\033_Gm=0;' | head -1 | cut -d: -f1)
last_m1_pos=$(printf '%s' "$out" | grep -abo $'\033_Gm=1;' | tail -1 | cut -d: -f1)
if [[ -n $first_m0_pos && -n $last_m1_pos && $first_m0_pos -gt $last_m1_pos ]]; then
  ok "final m=0 comes after last m=1 (correct order)"
else
  bad "final m=0 comes after last m=1 (m0@$first_m0_pos m1@$last_m1_pos)"
fi

# 6) a placement action (a=p) with c=<cols> — the pane-width scaling
if printf '%s' "$out" | grep -qEao $'\033_Ga=p,c=[0-9]+'; then
  ok "placement a=p,c=<cols> present (pane scaling)"
else
  bad "placement a=p,c=<cols> present"
fi

# 6b) SIZE sanity (FIT mode): placement box must fit the poster inside the
# pane using the CELL metrics (fallback 8x17 in this test env) — no crop, no
# over-narrowing. Oracle: independent re-computation of the expected c,r.
place=$(printf '%s' "$out" | grep -ao $'\033_Ga=p,c=[0-9]*,r=[0-9]*' | head -1)
pc=$(sed -E 's/.*c=([0-9]+),.*/\1/' <<<"$place")
pr=$(sed -E 's/.*,r=([0-9]+)/\1/' <<<"$place")
iw=1280; ih=720   # the 16:9 poster this test generates
pane_c=$(( $(tput cols 2>/dev/null || echo 80) - 2 ))
maxr=$(( $(tput lines 2>/dev/null || echo 24) - 10 )); (( maxr < 8 )) && maxr=8
CW=${CELL_W:-8}; CH=${CELL_H:-17}
or=$(( (pane_c * ih * CW + iw * CH / 2) / (iw * CH) ))
if (( or > maxr )); then
  oc=$(( (maxr * iw * CH + ih * CW / 2) / (ih * CW) )); (( oc < 8 )) && oc=8
  or=$(( (oc * ih * CW + iw * CH / 2) / (iw * CH) )); (( or > maxr )) && or=$maxr
else
  oc=$pane_c
fi
if [[ -n $pc && -n $pr ]] && (( pc == oc && pr == or )); then
  ok "placement fits poster in pane by cell oracle (c=$pc r=$pr)"
else
  bad "placement fits poster (got c=$pc r=$pr, oracle c=$oc r=$or)"
fi
# thumb must KEEP the poster aspect (no crop): |tw*ih - th*iw| <= 2%
twx=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$SESSION/thumb.png" 2>/dev/null)
tw=${twx%,*}; th=${twx#*,}
if [[ -n $tw && -n $th ]]; then
  d=$(( tw * ih - th * iw )); (( d < 0 )) && d=$(( -d ))
  (( d <= tw * ih / 50 )) && ok "thumb keeps poster aspect, no crop (${tw}x${th})" \
                          || bad "thumb aspect/crop (${tw}x${th})"
else
  bad "thumb.png probeable dimensions"
fi

# 6c) XTWINOPS parser (real kitty 0.49 responses from this machine):
CELL_W=8 CELL_H=17
probe_apply $'\e[8;49;89t' $'\e[4;1421;1157t'
(( CELL_W == 13 && CELL_H == 29 )) && ok "probe_apply parses kitty responses (13x29)" \
                                   || bad "probe_apply parses kitty responses (got ${CELL_W}x${CELL_H})"
CELL_W=8 CELL_H=17
probe_apply "garbage" "nonsense"
(( CELL_W == 8 && CELL_H == 17 )) && ok "probe_apply rejects garbage (keeps fallback)" \
                                  || bad "probe_apply rejects garbage"
CELL_W=8 CELL_H=17

# 7) no transmit may carry a w= display-width (that's the old broken form)
if printf '%s' "$out" | grep -qao $'\033_Ga=T[^\\]*w='; then
  bad "transmit carries no w= (old broken form)"
else
  ok "transmit carries no w= (scaling is a separate placement)"
fi

# 8) the emitted base64 payload must be exactly base64(thumb.png) — the PNG
#    render_poster wrote before encoding. This proves the transmit is complete
#    and uncorrupted (the original "failed some of the time" was a truncated /
#    dropped single giant APC). The base64 alphabet never contains
#    ESC/backslash, so stripping the APC control bytes leaves a deterministic
#    structure:  _Ga=d  _Ga=T,f=100,m=1;  <chunk1>  _Gm=1;  <chunk2>  _Gm=0;
#    _Ga=p,c=<cols>. The _Gm=1; markers sit BETWEEN the base64 chunks, so we
#    strip them (and the leading clear/transmit + trailing final/placement) to
#    recover the bare payload.
clean=$(printf '%s' "$out" | tr -d '\033' | tr -d '\\\\' | tr -d '\n')
payload=$(printf '%s' "$clean" \
  | sed -E 's/^_Ga=d//; s/^_Ga=T,f=100,m=1;//; s/_Gm=1;//g; s/_Gm=0;_Ga=p,c=[0-9]+(,r=[0-9]+)?$//')
thumb="$SESSION/thumb.png"
if [[ -s $thumb ]] && file "$thumb" 2>/dev/null | grep -qi 'PNG image'; then
  ok "intermediate thumb.png is a valid PNG"
else
  bad "intermediate thumb.png is a valid PNG"
  thumb=""
fi
if [[ -n $thumb ]]; then
  want=$(base64 -w0 "$thumb")
  if [[ $payload == "$want" ]]; then
    ok "emitted payload == base64(thumb.png) (complete, uncorrupted)"
  else
    # show where they first diverge for a useful failure
    n=0
    while (( n < ${#want} )) && (( n < ${#payload} )) && [[ ${payload:n:1} == "${want:n:1}" ]]; do n=$((n+1)); done
    bad "emitted payload == base64(thumb.png) (len ${#payload} vs ${#want}; first diff @ $n)"
  fi
fi

term=$'\033\\'                      # APC terminator (ESC + backslash)
# re-run with a sentinel: $(...) strips trailing newlines, and the padding
# after the placement IS the tail — the sentinel keeps it measurable.
outG=$(render_poster "test" 2>/dev/null; printf X)
tail_after=${outG##*"$term"}        # strip through the final placement APC
gap=${tail_after//[!$'\n']/}        # keep only newlines
gap=${#gap}
if [[ $gap == "$((pr+1))" ]]; then
  ok "separator blank line between picture and card (rows+1 = $gap newlines)"
else
  bad "gap after placement: got $gap expected $((pr+1))"

# 9) a clip with NO poster must not emit a transmit (and clears placements)
printf 'noposter\tvideo-test\t%s/videos/test.mp4\town\n' "$THEME" > "$SESSION/library.tsv"
rm -f "$SESSION"/poster-*
# rename the poster so poster_for() finds nothing
mv "$THEME/backgrounds/test.png" "$THEME/backgrounds/renamed.png"
out2=$(render_poster "noposter" 2>/dev/null)
if printf '%s' "$out2" | grep -qao $'\033_Ga=d\033' && ! printf '%s' "$out2" | grep -qao $'\033_Ga=T'; then
  ok "no-poster clip: clears placements, emits no transmit"
else
  bad "no-poster clip: clears placements, emits no transmit"
fi

# 6c) one extra separator newline between the picture bottom and the text
# card (padding = rows+1 after the placement). Last record after the final
# APC terminator is exactly that run of newlines.
fi

echo
echo "passed=$PASS failed=$FAIL"
[[ $FAIL -eq 0 ]]
