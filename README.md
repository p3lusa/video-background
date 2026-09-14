# Video Wallpaper

Desktop wallpaper renderer for [Omarchy](https://omarchy.org). Drop `videos/*.mp4` into any theme's directory and that theme plays them as a looping video wallpaper; themes without a `videos/` directory behave exactly like the stock image background.

## Features

- Plays the active theme's looping video on the `WlrLayer.Background` layer, per monitor (multi-monitor ready, hardware-accelerated decode via the Qt FFmpeg backend).
- Seamless image fallback: no videos, a corrupt file, or a decode error degrades to the theme's static background — never a black screen.
- Clip cycling: a theme can ship several clips; `omarchy theme bg next` advances to the next one.
- Power-friendly: the video pauses while the session is locked or idle, and resumes in place when the desktop returns.
- The video always matches the background: the clip is derived from the active background image (paired by file name), so cycling with `omarchy theme bg next` advances both in lockstep and they can never desync. The active clip also survives shell restarts for free (the background symlink is Omarchy's own persisted state).
- Drop-in replacement for the built-in `omarchy.background` service: same layer, same namespace, same IPC surface (`themeTransition`, background symlink tracking, transitions).
- Self-installing keybindings (video switcher carousel + prev/next) that only appear when you use a video tool, and are fully removable.
- `video-manage`: a gum-based terminal UI (themed by the active palette) to browse, play, add, and remove clips — with `video-add.sh` / `video-remove.sh` for the same operations from plain bash.

## Requirements

- Omarchy (this is an Omarchy shell plugin).
- No external dependencies — rendering uses the system Qt 6 Multimedia (FFmpeg backend), already part of Omarchy.

### Video assets

Videos are your own (any legal source). The bundled [video-wallpaper theme](https://github.com/p3lusa/video-wallpaper) ships three CC0/CC BY sample clips from Wikimedia Commons. Recommended spec (what the sample theme uses):

| Property | Value |
|---|---|
| Codec | H.264 (hardware-decoded on most GPUs) |
| Resolution | 1080p for laptop/1080p targets, 1440p or higher for 1440p+ panels |
| Frame rate | 24–30 fps |
| Bitrate | ~5–8 Mbps (CRF 20–23) |
| Audio | **none** — the Qt FFmpeg `MediaPlayer` exposes no mute/volume API, so clips must have no audio track |
| Length | 8–40 s, ideally a seamless loop |

A convenient encode:

```bash
ffmpeg -i input.mp4 -an -c:v libx264 -crf 23 -preset slow \
  -r 30 -vf "scale=1920:1080" -t 20 -movflags +faststart output.mp4
```

## Install

```bash
omarchy plugin add <this-repo-url> --enable
omarchy plugin disable omarchy.background
```

The first command installs and enables the plugin; the second hands the background layer over to it (only one background renderer should be active — they share the same layer namespace).

### Companion theme (recommended for the full experience)

The plugin works with *any* theme that ships a `videos/` directory, but the
companion [**video-wallpaper theme**](https://github.com/p3lusa/video-wallpaper)
is where the whole experience lives: it provides the library home that
`video-add` mirrors into, sample clips to start with, and the neon skin:

```bash
omarchy theme install https://github.com/p3lusa/video-wallpaper.git
omarchy theme set video-wallpaper
```

With both installed you get the complete feature set out of the box: video
wallpapers from your own clips, per-clip Aether palettes, the cycler, the
unified wallpaper switcher, and the `video-manage` library TUI. The theme is
optional — a plain image theme with a `videos/` directory added by hand works
too — but the library tools assume the `video-wallpaper` theme as the
library's home (if it's missing, `video-add` simply skips the mirror).

## Creating a theme from your own clip (Aether)

This plugin ships a helper, `bin/video-theme.sh` (installed at `~/.config/omarchy/plugins/p3lu.video-background/bin/video-theme.sh`), that turns any clip into a complete, palette-matched Omarchy theme in one command:

```bash
video-theme.sh <clip.mp4> [theme-name]   # default name: video-<clip base>
```

It extracts a poster frame from the clip, runs [Aether](https://github.com/omacom/aether) to derive the color palette and generate the full theme (terminal, bar, lock screen, …), installs it to `~/.config/omarchy/themes/<theme-name>/` with the clip in its `videos/` directory, and activates it. Result: video wallpaper and every accent color on the system come from the same clip.

Prerequisites: `aether` in `PATH`, `ffmpeg`/`ffprobe`, and this plugin enabled (without it the theme shows the poster image instead of the video). Each created theme is registered in the cycle list, so `video-next` / `video-prev` can walk them (see Usage). To update the clip later, replace the file in the theme's `videos/` directory and run `omarchy theme set <theme-name>`.

## Usage

### Library manager (TUI)

`video-manage.sh` is a terminal UI (built on `gum`, styled by the active
theme's palette) that does the whole job: browse the library with live
status (a themed header card, an accent-colored “● playing” marker, dimmed
kind tags), play any clip (video + palette), add a new clip through a
native file picker, and remove one with a confirmation prompt. Long
operations (Aether generation, removal) run behind a spinner with live
output.

```bash
video-manage
```

Every operation is also available non-interactively:

| Command | What it does |
|---|---|
| `video-add.sh <clip>` | Adds a clip: validates it (no audio track; non-`.mp4` containers are losslessly remuxed), creates the per-clip theme via Aether (own palette), registers it in the cycle list, and mirrors it into the library theme (`video-wallpaper`, hardlinks — zero extra space). `--strip-audio` drops an audio track first (lossless). |
| `video-remove.sh <name>` | Removes a clip from everywhere: its per-clip theme, every library copy (clip + poster), and the cycle-list entry. If the clip is the playing one it switches to another video theme first, and re-points the background if it would dangle. It never touches your original clip file. Accepts `07-rebecca-gun`, `video-07-rebecca-gun`, or with `.mp4`. |
| `video-theme.sh <clip>` | The original Aether helper: per-clip theme only (no library mirror). |

### One theme, many clips (one palette)

1. Put clips in the theme's source `videos/` directory — for an
   `omarchy theme install`ed theme that is
   `~/.config/omarchy/themes/<theme>/videos/` (create it if needed).
2. Switch to that theme: `omarchy theme set <theme>` (this re-stages the
   theme, including your clips).
3. Cycle clips: `omarchy theme bg next`.

All clips share the theme's palette.

### One theme per clip (each clip gets its own palette)

Clips usually don't share a mood, and a palette derived from clip A looks
wrong over clip B. The Aether helper solves this: each clip becomes its own
complete theme (see the Aether section above), and the plugin ships cycle
commands to walk them:

```bash
video-theme.sh ~/Videos/aurora.mp4      # creates + activates theme "video-aurora"
video-theme.sh ~/Videos/rain.mp4        # creates + activates theme "video-rain"
video-next                              # -> next clip + palette (wraps around)
video-prev                              # -> previous clip + palette
```

Note: a created theme is a regular Omarchy theme, so it also appears in the
stock theme switcher (Omarchy lists every installed theme — there is no
hidden-theme mechanism). With one theme per clip that is usually a feature:
the stock theme switcher becomes a second way to jump to any video + palette
pair. Cleanup is automatic: every theme created by `video-theme.sh` carries a
marker, and the next time any video tool runs, marked themes that are neither
active nor in the cycle list are removed (abandoned themes stop cluttering
the switcher). To remove one immediately: `omarchy theme remove <theme>`.

`video-next` / `video-prev` are installed at
`~/.config/omarchy/plugins/p3lu.video-background/bin/` (prepend that
directory to `PATH` to use them from a terminal). They walk the whole video
library — every clip of every theme that has videos, the same set the
switcher shows (per-clip themes win over library copies of the same clip,
so each video is visited exactly once). Theme order: the cycle list first
(`~/.config/omarchy/video-themes`, maintained by `video-theme.sh`), then any
remaining video themes alphabetically; clips within a theme are
alphabetical. Switching to a clip of another theme is an `omarchy theme set`
(palette, background, and video all switch together with the usual animated
transition); switching to another clip of the current theme only changes the
video (the palette stays). The position survives shell restarts (the active
theme + background are Omarchy's own state).

#### Keybindings (self-installing)

The first time you run any video tool (`video-theme.sh`, `video-next`,
`video-prev`, or the picker below), the plugin installs keybindings into
your `~/.config/hypr/bindings.lua` inside a self-contained marked block
(it never touches your own lines, and the block is refreshed in place if the
plugin moves):

| Key | Action |
|---|---|
| `Super+Ctrl+Space` | **Wallpaper switcher (unified)** — takes over the stock wallpaper key. On video themes it opens the video switcher (a carousel of your whole video library with poster previews); on image themes it opens the stock background picker, exactly as before. Selecting a clip of the active theme switches the video (same palette); selecting a clip from another theme switches video + palette |
| `Super+Ctrl+Alt+Left` | Previous video (cycles through the whole library) |
| `Super+Ctrl+Alt+Right` | Next video (cycles through the whole library) |
| `Super+Ctrl+Alt+V` | **Video library manager** (the `video-manage` TUI) — opens a terminal window with the full library UI: browse, play, add, remove. The window closes when you quit the TUI |

The unified picker is installed by unbinding the stock
`Super+Ctrl+Space` (Hyprland Lua `hl.unbind`) and rebinding it to
`video-bg-picker.sh`, which decides at press time which picker to open. So
the same key keeps working everywhere; only its content changes with the
active theme. Removing the block (`video-bindings.sh --remove`) restores
the stock behavior.

They are installed on use rather than at plugin install: a plugin install
hook does not exist in Omarchy, and the plugin should not claim your
keymap until you actually use the feature. To install them manually:
`video-bindings.sh` (in the plugin's `bin/` directory); to remove them:
`video-bindings.sh --remove`.

#### The video switcher

`video-switcher.sh` is a thin wrapper around Omarchy's image menu (the same
UI as the wallpaper switcher). It builds a poster carousel of your whole
video library: every clip of every user theme that has videos (each clip is a
background poster with a paired video in `videos/`). The list is stable — it
does not change when you cycle themes — so after `video-next`/`video-prev`
you still see every video.

Entry naming: the active theme's clips appear by clip name; a theme with a
single clip appears by theme name; clips from other themes are prefixed with
the theme name. The currently playing video is preselected.

A clip is never listed twice: when the same clip exists both as a per-clip
theme (created by `video-theme.sh`, marked with `.video-theme`) and as a
plain `videos/` entry of another theme, the per-clip theme wins — it carries
the clip's own palette, so the carousel and the prev/next cycle stay at one
entry per video.

Choosing an entry: a clip of the active theme runs `omarchy theme bg set`
(video changes, palette stays); a clip from another theme runs `omarchy
theme set` + `omarchy theme bg set` (video and palette change together).

### No videos at all

With a theme that has no `videos/` directory (the default for most themes), the plugin renders the static background exactly like the stock service — you can leave it enabled permanently.

## Uninstall

```bash
# remove the installed keybindings (if you used any video tool)
~/.config/omarchy/plugins/p3lu.video-background/bin/video-bindings.sh --remove

omarchy plugin remove p3lu.video-background --yes
omarchy plugin enable omarchy.background
```

Themes created with `video-theme.sh` are regular Omarchy themes and can be
removed like any other:

```bash
omarchy theme remove <theme-name>
```

(also removes it from the cycle list `~/.config/omarchy/video-themes`).

## How it works

The plugin resolves the active theme's `videos/*.mp4` files on every background/theme change (IPC + short poll of the `current/background` symlink). The playing clip is **derived from the current background image** by matching file base names, so the video and the image can never fall out of sync — the background symlink is the single source of truth (and Omarchy's persisted state, so the clip survives shell restarts). For each panel it creates one `MediaPlayer` + `VideoOutput` (`Qt.KeepAspectRatioByExpanding` fill), starts the video only after the first decoded frame (the static background stays visible underneath until then), and pauses playback while the session is locked or idle.

The background layer can occasionally end up with a stale (uncommitted) surface buffer after a shell restart or a long time parked behind the lock screen, which would leave a flat desktop. As a safeguard, at startup and on every unlock the plugin forces an invisible re-render (the reveal transition runs with the same image on both sides, so nothing changes visually), which re-commits the surface if it was stale — the wallpaper always shows up.

## GPU acceleration

The video is decoded by Qt 6 Multimedia's FFmpeg backend (the `MediaPlayer` in `Background.qml`), so hardware acceleration is a **session-environment** concern, not a per-script flag. The plugin detects your GPU(s) and injects the right `QT_FFMPEG_*` variables into the compositor session so the decode runs on the GPU instead of the CPU.

**How it works.** `bin/video-hwaccel.sh` enumerates **every** display GPU (integrated and dedicated, via `lspci`) and maps each `/dev/dri` render node to its physical chip, then writes:

- `hwaccel.env` — the `QT_FFMPEG_*` variables for the detected backend
- `hwaccel.log` — a readable record of every GPU, the chosen backend, and the render node (useful for debugging on other hardware)

`video-hwaccel.sh --apply` turns that into a **systemd-user drop-in** on the `wayland-wm@.service` template, so the compositor session (and `quickshell` within it) inherits the variables. It is idempotent and survives `omarchy refresh` / `omarchy update` — unlike a manual `export` or a Hyprland `autostart.lua` line (which `omarchy refresh hyprland` clobbers).

**Backend by vendor** (short, per-vendor list; Qt falls back to CPU if the backend can't handle the stream):

| GPU | Backend | Env injected |
|---|---|---|
| NVIDIA (dedicated) | `cuda` (NVDEC) | `QT_FFMPEG_DECODING_HW_DEVICE_TYPES=cuda` |
| AMD (iGPU or dGPU) / Intel iGPU | `vaapi` | `QT_FFMPEG_DECODING_HW_DEVICE_TYPES=vaapi` + `QT_FFMPEG_HW_ALLOW_PROFILE_MISMATCH=1` |
| none usable | CPU (Qt default) | *(none — comment only; never breaks the wallpaper)* |

**Auto-configuration (no action needed).** The backend is chosen automatically and applied for you at two points:

- **First time you add a clip** (`video-add.sh`) — the plugin detects your GPU(s) and applies the result.
- **After every `omarchy update`** — the `post-update` hook re-runs detection + apply, so the config tracks any hardware change.

Both run `video-hwaccel.sh --apply`, which writes the `hwaccel.env` + `hwaccel.log` and (re)creates the systemd drop-in. It is idempotent and **respects any override you've set** (see below) — it never silently resets a deliberate choice. The variables take effect at the **next session start** (log out/in, or `systemctl --user restart wayland-wm@.service`); the currently running session is left untouched.

**How to change it (override the auto-config).** The effective config follows one rule: **a user override wins; otherwise auto-detection applies.** You can change the backend three ways:

1. **Force a backend (CLI).** From the plugin's `bin/` directory:
   ```bash
   video-hwaccel.sh --set-backend vaapi     # or: cuda | cpu
   ```
   `--set-backend` writes the override file, applies it, and is the quickest fix when the auto-detection guessed wrong. Use `cpu` to **disable hardware acceleration entirely** (the drop-in is removed).

2. **Edit the config by hand.** Create or edit `~/.config/omarchy/video-hwaccel.conf` and put any `KEY=VALUE` lines in it. When this file exists, its env lines **replace** the auto-detected ones verbatim — full manual control, e.g.:
   ```bash
   # ~/.config/omarchy/video-hwaccel.conf
   QT_FFMPEG_DECODING_HW_DEVICE_TYPES=vaapi
   QT_FFMPEG_HW_ALLOW_PROFILE_MISMATCH=1
   ```
   A file with **no** env lines forces CPU decode. Then re-apply with `video-hwaccel.sh --apply` (or just log out/in).

3. **Go back to auto-detection.** Either delete the override file, or run:
   ```bash
   video-hwaccel.sh --auto
   ```

**Check the current state at any time:**
   ```bash
   video-hwaccel.sh --status
   ```
   It shows whether auto-detection or a user override is in effect, the effective backend, the exact env vars, and whether the session drop-in is present.

**Examples**

| Goal | Command |
|---|---|
| Auto-detection said `vaapi` but I want `cuda` | `video-hwaccel.sh --set-backend cuda` |
| HW decode is misbehaving → fall back to CPU | `video-hwaccel.sh --set-backend cpu` |
| I edited the conf by hand; apply it | `video-hwaccel.sh --apply` |
| Undo any override, trust auto-detection again | `video-hwaccel.sh --auto` |
| See what's currently in effect | `video-hwaccel.sh --status` |

The override file lives **outside the plugin directory** (`~/.config/omarchy/`) on purpose, so `omarchy plugin update` never clobbers it.

**Hybrid iGPU + dGPU.** Both chips are listed in `hwaccel.log` and the non-Intel (dedicated) node is preferred. Note: the Qt FFmpeg backend cannot be pinned to a specific render node (no such env var), so on a hybrid the VAAPI decode uses the session's default node — still a real hardware decode, just not guaranteed to be the dGPU. On NVIDIA this is a non-issue (`cuda` always targets the dGPU). If auto-detection picks the "wrong" node on your hybrid, force one explicitly with `--set-backend` or the override file.

To check it's decoding on the GPU: with a video wallpaper active, `ls -l /proc/$(pgrep -x quickshell | head -1)/fd | grep -c renderD` should be higher than the 3 file descriptors it opens for compositing alone, and `quickshell`'s CPU usage should be minimal.

## Known limitations

- No crossfade between clips (the previous frame stays visible for a few hundred ms while the next clip's first frame decodes).
- One clip is active on all monitors (per-monitor clip selection is not implemented).
- A video only plays while its paired background image (same base name) is the active background — videos without a paired image are ignored.
- If you run `omarchy refresh shell` by hand, re-apply the state with:
  ```bash
  omarchy plugin enable p3lu.video-background
  omarchy plugin disable omarchy.background
  ```
  (The `video-wallpaper` theme ships a `post-update` hook that does this automatically after `omarchy update` when its theme is active.)

## License

[MIT](LICENSE). This plugin is derived from the stock `omarchy.background` service of [Omarchy](https://github.com/omacom/omarchy) (MIT); the video branch is layered on top of its image renderer. Thanks to the Omarchy team.
