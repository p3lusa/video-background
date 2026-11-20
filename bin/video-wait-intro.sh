#!/usr/bin/env bash
# video-wait-intro.sh — wait out a theme-switch intro so the loop load that
# follows does not kill it.
#
# `omarchy theme set` on a theme that ships backgrounds/intros/<stem>.* starts
# a one-shot intro through owed (native Omarchy 4.5 plumbing). Changing the
# background symlink while an intro is running ends it early — so the video
# scripts call this right after `theme set` and before pointing the symlink
# at the loop clip. Fast no-op when no intro is running.

set -u

command -v owe >/dev/null 2>&1 || exit 0

intro_running() {
  timeout 2 owe raw '{"cmd":"intro-status"}' 2>/dev/null | jq -r '.running // false' | grep -qx true
}

intro_running || exit 0

echo "intro playing (theme switch) — waiting up to 34 s for it to finish…" >&2
for _ in $(seq 1 34); do
  sleep 1
  intro_running || break
done
exit 0
