#!/usr/bin/env bash
# test_security.sh — unit tests for the video-manage.sh security gates.
# Sources the script with VM_NO_MAIN=1 and exercises validate_video_path /
# dir_is_safe / browser_list with a real sandbox tree, including symlink
# escapes. Run: test_security.sh (from anywhere).
set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
MANAGE="$SCRIPT_DIR/bin/video-manage.sh"
SANDBOX="$(mktemp -d)"
PASS=0 FAIL=0
trap 'rm -rf "$SANDBOX"' EXIT

# fake HOME so $HOME-based rules point at the sandbox
export HOME="$SANDBOX/home"
mkdir -p "$HOME/Downloads" "$HOME/Videos" "$HOME/.ssh" "$HOME/.gnupg" \
         "$HOME/.password-store" "$HOME/.config/omarchy/plugins" \
         "$HOME/.local/state/omarchy" "$HOME/.cache/omarchy"

# --- source the script (functions only) -------------------------------------
VM_NO_MAIN=1 . "$MANAGE"

ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }

expect_ok() { # <desc> <fn> <path>
  if REJECT_REASON="" "$2" "$3" >/dev/null 2>&1; then ok "$1"; else bad "$1 (rejected: ${REJECT_REASON:-?})"; fi
}
expect_bad() { # <desc> <fn> <path>
  if REJECT_REASON="" "$2" "$3" >/dev/null 2>&1; then bad "$1 (accepted!)"; else ok "$1"; fi
}

# --- fixtures ----------------------------------------------------------------
echo test > "$HOME/Downloads/test.mp4"
echo x > "$HOME/Downloads/not-a-video.txt"
echo x > "$HOME/Downloads/UPPER.MP4"
mkdir -p "$HOME/Downloads/sub"
echo v > "$HOME/Downloads/sub/inner.mp4"

# outside-home targets
mkdir -p "$SANDBOX/outside"
echo o > "$SANDBOX/outside/out.mp4"
ln -s "$SANDBOX/outside/out.mp4" "$HOME/Downloads/escape-file.mp4"
ln -s "$SANDBOX/outside" "$HOME/Downloads/escape-dir"
ln -s "$HOME/Downloads/test.mp4" "$HOME/Downloads/good-link.mp4"
ln -s /etc/hostname "$HOME/Downloads/etc-escape.mp4"
echo secret > "$HOME/.ssh/id_fake"

# --- validate_video_path ------------------------------------------------------
expect_ok  "mp4 in Downloads accepted"        validate_video_path "$HOME/Downloads/test.mp4"
expect_ok  "uppercase extension accepted"     validate_video_path "$HOME/Downloads/UPPER.MP4"
expect_ok  "nested mp4 accepted"              validate_video_path "$HOME/Downloads/sub/inner.mp4"
expect_ok  "symlink INSIDE home accepted"     validate_video_path "$HOME/Downloads/good-link.mp4"
expect_bad "symlink escaping home rejected"   validate_video_path "$HOME/Downloads/escape-file.mp4"
expect_bad "symlink to /etc rejected"         validate_video_path "$HOME/Downloads/etc-escape.mp4"
expect_bad "non-video extension rejected"     validate_video_path "$HOME/Downloads/not-a-video.txt"
expect_bad "file in .ssh rejected"            validate_video_path "$HOME/.ssh/id_fake"
expect_bad "file in .gnupg rejected"          validate_video_path "$HOME/.gnupg/none"
expect_bad "file in .password-store rejected" validate_video_path "$HOME/.password-store/x"
expect_bad "file in omarchy config rejected"  validate_video_path "$HOME/.config/omarchy/x.mp4"
expect_bad "file in omarchy state rejected"   validate_video_path "$HOME/.local/state/omarchy/x.mp4"
expect_bad "file in omarchy cache rejected"   validate_video_path "$HOME/.cache/omarchy/x.mp4"
expect_bad "nonexistent file rejected"        validate_video_path "$HOME/Downloads/ghost.mp4"
expect_bad "directory (not a file) rejected"  validate_video_path "$HOME/Downloads/sub"

# resolved path must be printed on success
out=$(validate_video_path "$HOME/Downloads/good-link.mp4") || true
[[ $out == "$HOME/Downloads/test.mp4" ]] && ok "resolved path printed (follows symlink)" || bad "resolved path printed (got: $out)"

# --- dir_is_safe ---------------------------------------------------------------
expect_ok  "home itself allowed"              dir_is_safe "$HOME"
expect_ok  "Downloads allowed"                dir_is_safe "$HOME/Downloads"
expect_ok  "nested dir allowed"               dir_is_safe "$HOME/Downloads/sub"
expect_ok  "Videos allowed"                   dir_is_safe "$HOME/Videos"
expect_bad "dir escaping home rejected"       dir_is_safe "$HOME/Downloads/escape-dir"
expect_bad "outside-home dir rejected"        dir_is_safe "$SANDBOX/outside"
expect_bad "/etc rejected"                    dir_is_safe /etc
expect_bad "root dir rejected"                dir_is_safe /
expect_bad ".ssh dir rejected"                dir_is_safe "$HOME/.ssh"
expect_bad ".gnupg dir rejected"              dir_is_safe "$HOME/.gnupg"
expect_bad "omarchy config dir rejected"      dir_is_safe "$HOME/.config/omarchy"
expect_bad "omarchy state dir rejected"       dir_is_safe "$HOME/.local/state/omarchy"
expect_bad "nonexistent dir rejected"         dir_is_safe "$HOME/nope"

# --- browser_list (UI must never list unsafe entries) --------------------------
list=$(browser_list "$HOME/Downloads")
printf '%s\n' "$list" | grep -qx "escape-dir/" && bad "browser_list hides symlink-escaping dirs" || ok "browser_list hides symlink-escaping dirs"
printf '%s\n' "$list" | grep -qx "sub/" && ok "browser_list lists real subdirs" || bad "browser_list lists real subdirs"
printf '%s\n' "$list" | grep -qx "test.mp4" && ok "browser_list lists video files" || bad "browser_list lists video files"
printf '%s\n' "$list" | grep -q "not-a-video.txt" && bad "browser_list hides non-video files" || ok "browser_list hides non-video files"
# dirs must come before files
first_dir=$(printf '%s\n' "$list" | grep -n '/$' | head -1 | cut -d: -f1)
first_file=$(printf '%s\n' "$list" | grep -nv '/$' | head -1 | cut -d: -f1)
[[ -n $first_dir && -n $first_file && $first_dir -lt $first_file ]] && ok "browser_list orders dirs before files" || bad "browser_list orders dirs before files"

# --- do_add start-directory selection logic ------------------------------------
start=""
for d in "$HOME/Downloads" "$HOME/Videos" "$HOME"; do
  if [[ -d $d ]] && dir_is_safe "$d"; then start=$d; break; fi
done
[[ $start == "$HOME/Downloads" ]] && ok "do_add starts in Downloads" || bad "do_add starts in Downloads (got: $start)"

# --- summary --------------------------------------------------------------------
echo
echo "passed=$PASS failed=$FAIL"
[[ $FAIL -eq 0 ]]
