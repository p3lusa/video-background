# Video Wallpaper Manager

Video-wallpaper **manager** for [Omarchy](https://omarchy.org), built on the
[OWE wallpaper engine](https://github.com/omacom/owe). Every clip you add gets
its own theme, so the **video, the shell palette, and the wallpaper always
change together** — pick a clip and the whole desktop re-skins to match it.

Rendering is delegated to `owed` (the OWE wallpaper daemon, native to Omarchy
4.5): one decode for all monitors, hardware decode (VAAPI/CUDA via mpv
`auto-safe`), seamless loops, crossfades, pause policies (lock, idle,
fullscreen, DPMS, sleep, battery), GIF transcoding, and login intros. This
plugin adds the library, the per-clip theming, and the hotkeys on top.

## Requirements

- Omarchy 4.5+.
- The wallpaper engine:
  ```bash
  omarchy pkg add owe
  systemctl --user enable --now owed.service
  ```
  The plugin ships no renderer of its own (since v0.8); it drives owe through
  the plain Omarchy background symlink.

## How it works

```
video-manage (TUI) / hotkeys
  ├─ video-theme.sh   → creates theme video-<clip> (palette extracted from the clip)
  ├─ omarchy theme set video-<clip>                → palette + defaults
  └─ omarchy theme bg set videos/<clip>.mp4        → the background symlink names the clip
       └─ owed (inotify) takes the wallpaper layer and renders the clip
```

The paired poster stays in the theme's `backgrounds/` as the clip's still
partner: picker thumbnail, lock screen, and battery-poster mode.

## Install

```bash
omarchy plugin add <this-repo-url> --enable
```

That's all. The plugin no longer replaces the stock background service — the
stock service draws stills and owe takes the layer while a video plays, so
there is nothing to disable.

### Companion theme (recommended)

The [**video-wallpaper theme**](https://github.com/p3lusa/video-wallpaper)
provides the library home `video-add` mirrors into, sample clips, and the
neon skin:

```bash
omarchy theme install https://github.com/p3lusa/video-wallpaper.git
```

The theme alone only shows static images — this plugin is what turns a clip
into video + palette.

## Adding clips (one theme per clip, each with its own palette)

```bash
video-theme.sh ~/Videos/aurora.mp4      # creates + activates theme "video-aurora"
video-next                              # next clip + palette (wraps around)
video-prev                              # previous clip + palette
```

`video-theme.sh` extracts a poster frame, runs
[Aether](https://github.com/omacom/aether) to derive the palette, builds the
full theme (terminal, bar, lock screen, …), installs it with the clip in its
`videos/` directory, and points the wallpaper at the clip. Result: the video
wallpaper and every accent color come from the same frame.
Prerequisites: `aether` in `PATH` and `ffmpeg`/`ffprobe`.

Created themes carry a marker; abandoned ones are reaped automatically the
next time a video tool runs (`video-cleanup.sh`).

## Library manager (TUI)

`video-manage` (keybind below) is a `gum`-based terminal UI, themed by the
active palette: browse with a "● playing" marker, preview, play (video +
palette), add (multi-select, bulk folder), remove, re-extract palettes.
**`o` opens the engine menu**: live `owe` status (engine, hwdec, pause
reasons), manual pause/resume, `always-animate`, and the battery policy
(writes `[pause] battery_mode` into `~/.config/owe/config.toml` for you).
Non-interactive equivalents:

| Command | What it does |
|---|---|
| `video-add.sh <clip>` | Validate (remux non-mp4 losslessly; `--strip-audio` optional), create the per-clip Aether theme, register in the cycle, mirror into the library theme (hardlinks). |
| `video-remove.sh <name>` | Remove the clip + theme + cycle entry everywhere; heals the background if it was playing. Never touches your original file. |
| `video-theme.sh <clip>` | Per-clip theme only (no library mirror). |
| `video-owe.sh <op>` | Engine ops: `status`, `pause`, `resume`, `animate on/off`, `battery play\|pause\|poster`. |

A plain image theme with a hand-added `videos/` directory also works —
`video-next`/`video-switcher` pick up any theme with paired
`backgrounds/<base>.<img>` + `videos/<base>.<ext>` clips
(mp4, mkv, webm, mov, avi).

## Keybindings (self-installing)

The first run of any video tool installs a self-contained marked block in
`~/.config/hypr/bindings.lua` (your own lines are never touched):

| Key | Action |
|---|---|
| `Super+Ctrl+Space` | Unified wallpaper switcher: video carousel on video themes, stock picker elsewhere. |
| `Super+Ctrl+Alt+←/→` | Previous / next clip (whole library, video + palette together). |
| `Super+Ctrl+Alt+V` | Library manager TUI. |

Install manually: `video-bindings.sh` — remove: `video-bindings.sh --remove`
(restores stock behavior).

## Engine state and knobs

The engine is observable and configurable through its own CLI:

```bash
owe status          # who owns the layer, pause reasons (fullscreen/idle/battery…)
owe render-status   # hwdec in use, errors, current clip
owe config          # effective config
owe pause / resume / always-animate on
```

`~/.config/owe/config.toml`: e.g. `battery_mode = "poster"` (default keeps
decoding on battery), `[pause] blocklist`, `[render] fade_ms`.

Known engine quirk (owed 0.2.x): if a fullscreen window appears exactly
while the theme is switching, the auto-pause can trip before the clip's
first frame and owed parks the still instead. Nothing is broken — `owe
refresh` (or opening any video tool) loads the clip immediately.

## Video assets

mpv-backed: mp4, mkv, webm, mov, avi, mpeg, ts, wmv, flv, ogv, 3gp (GIFs
transcoded by owe). Recommended: H.264, 24–30 fps, CRF 20–23, 8–40 s,
seamless. **Decide about audio deliberately**: unlike a muted renderer, owe
plays a clip's audio track through the default output — strip it (`-an`)
unless you want sound.

```bash
ffmpeg -i input.mp4 -an -c:v libx264 -crf 23 -preset slow \
  -r 30 -vf "scale=1920:1080" -t 20 -movflags +faststart output.mp4
```

## Uninstall

```bash
~/.config/omarchy/plugins/io.github.p3lu.video-background/bin/video-bindings.sh --remove
omarchy plugin remove io.github.p3lu.video-background --yes
omarchy theme remove <video-theme-name>   # per-clip themes are regular themes
```

Stills keep working — the stock service and owe handle everything else.

## Version note (v0.8)

v0.8 replaced the plugin's Qt Multimedia renderer with the OWE engine. The
plugin now ships scripts, the TUI, and keybindings only; the `Manager.qml`
service entry point is an intentional no-op kept because the manifest schema
requires a kind. The old engine lives on the `legacy-qml` branch. Rationale
and migration: `PLAN-owe-parity.md`.

## License

[MIT](LICENSE). Thanks to the [Omarchy](https://github.com/omacom/omarchy)
team and the [OWE](https://github.com/omacom/owe) engine.
