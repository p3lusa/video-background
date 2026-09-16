#!/usr/bin/env bash
# video-hwaccel.sh -- detect the user's GPU(s) and set up GPU-accelerated
# video decoding for the wallpaper (Qt Multimedia FFmpeg backend).
#
# The wallpaper is decoded by Qt Multimedia's FFmpeg backend (Background.qml's
# MediaPlayer), NOT by any .sh script. The plugin reads QT_FFMPEG_* variables
# from the session environment:
#   QT_FFMPEG_DECODING_HW_DEVICE_TYPES   (e.g. "vaapi" or "cuda")
#   QT_FFMPEG_HW_ALLOW_PROFILE_MISMATCH  (broaden VAAPI profile coverage)
# Without them, Qt probes vdpau -> vulkan -> cuda before vaapi, which on
# integrated AMD/Intel GPUs spams the journal with "Invalid setup for format"
# and may fall back to CPU decode.
#
# MODES:
#   (no args)       detection only: writes hwaccel.env + hwaccel.log next to
#                   this script. Nothing is applied to the session.
#   --apply         detection + writes a systemd-user drop-in on the
#                   wayland-wm@.service template so the compositor session
#                   (and quickshell within it) inherits the variables.
#                   Idempotent: safe to run on every post-update.
#   --status        show the effective config (auto vs override, backend,
#                   env vars, drop-in state).
#   --set-backend X force a backend (X = cuda | vaapi | cpu): writes a user
#                   override file that bypasses auto-detection, then applies.
#   --auto          remove the user override, re-run auto-detection + apply.
#
# USER OVERRIDE (escape hatch for a wrong auto-detection):
#   $HOME/.config/omarchy/video-hwaccel.conf. If it exists, its KEY=VALUE
#   lines replace the auto-detected env verbatim (a file created by
#   --set-backend counts even when it holds no env lines, e.g. forced CPU).
#   Edit it freely: any KEY=VALUE line is injected into the session. Remove
#   it (or run --auto) to re-enable auto-detection. It lives outside the
#   plugin directory on purpose, so it survives `omarchy plugin update`.
#
# Detection (see docs/PLAN-hwaccel-gpu.md):
#   NVIDIA (dedicated)                 -> cuda   (NVDEC lives on the dGPU)
#   Intel iGPU / AMD (iGPU or dGPU)    -> vaapi  (VAAPI covers both)
#   nothing usable                     -> cpu    (comment-only env; never break)
# All display GPUs (integrated AND dedicated) are enumerated via lspci and
# each /dev/dri render node is mapped to its physical GPU by PCI. On hybrid
# iGPU+dGPU the non-Intel (dedicated) node is preferred in the log. The Qt
# FFmpeg backend cannot be pinned to a specific render node (no such env var),
# so on a hybrid VAAPI uses the session default node; the log still shows
# exactly which chip owns which node.

set -euo pipefail

PLUGIN_BIN="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PLUGIN_ROOT="$(dirname "$PLUGIN_BIN")"
ENV_FILE="$PLUGIN_ROOT/hwaccel.env"
LOG_FILE="$PLUGIN_ROOT/hwaccel.log"
# DRM root is overridable for testability / exotic layouts (default /dev/dri).
DRI_ROOT="${VIDEO_HWACCEL_DRI_ROOT:-/dev/dri}"
# systemd-user template the compositor session runs under (uwsm/Omarchy).
WM_TEMPLATE="wayland-wm@.service"
DROPIN_DIR="$HOME/.config/systemd/user/${WM_TEMPLATE}.d"
DROPIN_FILE="$DROPIN_DIR/10-video-hwaccel.conf"
# User override (escape hatch for wrong auto-detection). Lives OUTSIDE the
# plugin directory so `omarchy plugin update` never clobbers it.
OVERRIDE_FILE="$HOME/.config/omarchy/video-hwaccel.conf"

# --- helpers -----------------------------------------------------------------
lsmod_mods="$(lsmod 2>/dev/null | awk 'NR>0{print $1}' || true)"
has_mod() { grep -qx "$1" <<<"$lsmod_mods" 2>/dev/null; }

# classify a full lspci vendor line -> nvidia | amd | intel | other
classify() {
  if   grep -qi 'nvidia' <<<"$1"; then echo nvidia
  elif grep -qiE 'advanced micro devices|amd/ati' <<<"$1"; then echo amd
  elif grep -qi 'intel'  <<<"$1"; then echo intel
  else echo other; fi
}

# normalise a PCI id to "B:D.F" (drop the "0000:" domain and any -card/-render)
norm_pci() {
  local p="$1"
  p="${p#pci-}"; p="${p%%-card}"; p="${p%%-render}"
  p="${p#0000:}"
  printf '%s' "$p"
}

# --- GPU discovery: enumerate EVERY display GPU ------------------------------
lspci_all=""
declare -a GPU_PCI=() GPU_DRV=() GPU_LINE=()
if command -v lspci >/dev/null 2>&1; then
  lspci_all="$(lspci -nnk 2>/dev/null || true)"
  _cur_pci=""; _cur_drv=""; _cur_line=""; _cur_keep=false
  while IFS= read -r _line; do
    # A line starting with a PCI address ends the previous display block:
    # flush it first. Only VGA/3D/Display controllers count as GPUs.
    if [[ $_line =~ ^[0-9a-fA-F]{1,4}:[0-9a-fA-F]{2}\.[0-9a-fA-F] ]]; then
      if [[ -n $_cur_pci && -n $_cur_line ]]; then
        GPU_PCI+=("$_cur_pci"); GPU_DRV+=("$_cur_drv"); GPU_LINE+=("$_cur_line")
      fi
      _cur_pci=""; _cur_keep=false
      if [[ $_line == *"VGA compatible controller"* \
           || $_line == *"3D controller"* \
           || $_line == *"Display controller"* ]]; then
        _cur_pci="${_line%% *}"
        _cur_line="$_line"
        _cur_drv=""
        _cur_keep=true
      fi
      continue
    fi
    case "$_line" in
      *"Kernel driver in use: "*)
        if [[ -n $_cur_pci && $_cur_keep == true ]]; then
          _d="${_line##*: }"
          _cur_drv="${_d// /}"
        fi
        ;;
    esac
  done <<<"$lspci_all"
  if [[ -n $_cur_pci && -n $_cur_line && $_cur_keep == true ]]; then
    GPU_PCI+=("$_cur_pci"); GPU_DRV+=("$_cur_drv"); GPU_LINE+=("$_cur_line")
  fi
fi

# Map each VAAPI render node to the PCI GPU it belongs to (via by-path symlinks).
declare -A NODE_PCI=() PCI_NODE=()
for f in "$DRI_ROOT"/by-path/*-render; do
  [[ -e $f ]] || continue
  pci="$(norm_pci "$(basename "$f")")"
  node="$(basename "$(readlink -f "$f")")"
  NODE_PCI["$node"]="$pci"; PCI_NODE["$pci"]="$node"
done
render_nodes="$(ls -1 "$DRI_ROOT"/renderD* 2>/dev/null | sort || true)"

# --- pick the decode backend --------------------------------------------------
vendor=""   # nvidia | vaapi | none
gpu=""      # amd | intel | unknown (only for vaapi)
backend=""  # cuda | vaapi | cpu
render_node=""

# 1) NVIDIA wins outright: its NVDEC lives on the dedicated GPU.
nvidia_ok=false
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then nvidia_ok=true; fi
[[ -e /dev/nvidia0 ]] && nvidia_ok=true
for i in "${!GPU_PCI[@]}"; do
  if [[ $(classify "${GPU_LINE[$i]}") == nvidia && -n ${GPU_DRV[$i]:-} ]]; then
    nvidia_ok=true; break
  fi
done
if $nvidia_ok; then
  vendor="nvidia"; backend="cuda"; gpu="nvidia"
fi

# 2) Else VAAPI if a render node exists. Prefer a non-Intel (dedicated) node
#    when there are several, so a hybrid iGPU+dGPU uses the dGPU.
if [[ -z $vendor && -n $render_nodes ]]; then
  vendor="vaapi"; backend="vaapi"
  best=""
  while IFS= read -r n; do
    [[ -n $n ]] || continue
    p="${NODE_PCI[$(basename "$n")]:-}"; v=""
    if [[ -n $p ]]; then
      for i in "${!GPU_PCI[@]}"; do
        [[ ${GPU_PCI[$i]} == "$p" ]] && { v="$(classify "${GPU_LINE[$i]}")"; break; }
      done
    fi
    if [[ -z $best ]]; then best="$n"
    elif [[ -n $v && $v != intel ]]; then best="$n"; fi
  done <<<"$render_nodes"
  render_node="$best"
  if has_mod amdgpu || grep -qiE 'advanced micro devices|amd/ati' <<<"$lspci_all"; then gpu="amd"
  elif has_mod i915 || grep -qi 'intel' <<<"$lspci_all"; then gpu="intel"
  else gpu="unknown"; fi
fi

# 3) No GPU hwaccel available: leave the backend at Qt's CPU default.
if [[ -z $vendor ]]; then
  vendor="none"; gpu="none"; backend="cpu"; render_node=""
fi

# Remember what pure auto-detection decided, so --status can show it side by
# side with the effective (possibly overridden) backend.
auto_backend="$backend"

# --- USER OVERRIDE (escape hatch) ---------------------------------------------
# If the user has a config file, it wins over auto-detection: its env lines are
# used verbatim (a file with no env lines forces CPU decode). This lets the
# user fix a wrong auto-detection without touching the plugin.
override_active=false
override_env_body=""
if [[ -f $OVERRIDE_FILE ]]; then
  override_active=true
  override_env_body="$(grep -vE '^[[:space:]]*(#|$)' "$OVERRIDE_FILE" || true)"
  if [[ -n $override_env_body ]]; then
    env_body="$override_env_body"
    # Derive the effective backend label from the decoding-device-types line.
    _dt="$(grep -E '^QT_FFMPEG_DECODING_HW_DEVICE_TYPES=' <<<"$override_env_body" | head -1 || true)"
    if   [[ $_dt == *cuda* ]];  then backend="cuda"
    elif [[ $_dt == *vaapi* ]]; then backend="vaapi"
    else backend="cpu"; fi
    echo "video-hwaccel: using user override ($OVERRIDE_FILE); auto-detection bypassed."
  else
    # Override file present but empty of env lines -> force CPU.
    env_body="# user override forced CPU decode (no env vars)"
    backend="cpu"
    echo "video-hwaccel: user override forces CPU decode (no env vars set)."
  fi
else
  # No override: use the auto-detected env.
  if [[ $backend == "cuda" ]]; then
    env_body="QT_FFMPEG_DECODING_HW_DEVICE_TYPES=cuda"
  elif [[ $backend == "vaapi" ]]; then
    env_body="QT_FFMPEG_DECODING_HW_DEVICE_TYPES=vaapi
QT_FFMPEG_HW_ALLOW_PROFILE_MISMATCH=1"
  else
    env_body="# no GPU hwaccel detected -> CPU decode (Qt default)"
  fi
fi

# --- write hwaccel.env -------------------------------------------------------
mkdir -p "$PLUGIN_ROOT"
printf '%s\n' "$env_body" > "$ENV_FILE"

# --- log ---------------------------------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")"
{
  echo "video-hwaccel: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ ${#GPU_PCI[@]} -gt 0 ]]; then
    echo "  GPUs detected:"
    for i in "${!GPU_PCI[@]}"; do
      v="$(classify "${GPU_LINE[$i]}")"
      drv="${GPU_DRV[$i]:-<none>}"
      node="${PCI_NODE[${GPU_PCI[$i]}]:-<no render node>}"
      echo "    ${GPU_PCI[$i]}  ${v}  driver=${drv}  node=${node}"
    done
  else
    echo "  GPUs detected: none (lspci unavailable or no display GPU)"
  fi
  echo "  backend:     ${backend}"
  echo "  gpu family:  ${gpu}"
  echo "  render node: ${render_node:-n/a}"
  if [[ $override_active == true ]]; then
    echo "  override:    YES (user config: ${OVERRIDE_FILE})"
  else
    echo "  override:    no (auto-detection)"
  fi
  echo "  env file:    ${ENV_FILE}"
  echo "  env vars:"
  sed 's/^/      /' <<<"$env_body"
  if [[ $backend == "vaapi" ]]; then
    _n_nodes=0
    [[ -n $render_nodes ]] && _n_nodes="$(grep -c . <<<"$render_nodes")"
    if [[ $_n_nodes -gt 1 ]]; then
      echo ""
      echo "  NOTE: multiple render nodes (hybrid iGPU+dGPU). The Qt FFmpeg backend"
      echo "        cannot be pinned to a node, so VAAPI uses the session default"
      echo "        node. The GPUs above show which node belongs to which chip."
    fi
  fi
} >> "$LOG_FILE"

# --- apply mode: systemd-user drop-in on the WM session template --------------
apply_dropin() {
  # CPU decode (no hwaccel, or a user override that set no env vars) -> remove
  # any existing drop-in so the session runs on Qt's clean CPU default.
  if [[ $backend == "cpu" ]]; then
    if [[ -f $DROPIN_FILE ]]; then
      rm -f "$DROPIN_FILE"
      rmdir --ignore-fail-on-non-empty "$DROPIN_DIR" 2>/dev/null || true
      systemctl --user daemon-reload
      echo "video-hwaccel: CPU decode active; removed drop-in (no env injected)."
    else
      echo "video-hwaccel: CPU decode active; nothing to apply (no drop-in)."
    fi
    return 0
  fi
  local wm_unit
  wm_unit="$(systemctl --user list-unit-files 2>/dev/null | awk '{print $1}' | grep -E '^wayland-wm@' | head -1 || true)"
  if [[ -z $wm_unit ]]; then
    echo "video-hwaccel: WARNING: no wayland-wm@*.service found in user units."
    echo "  The session env will NOT be updated automatically. Manual fallback:"
    echo "    export QT_FFMPEG_DECODING_HW_DEVICE_TYPES=${backend}"
    [[ $backend == vaapi ]] && echo "    export QT_FFMPEG_HW_ALLOW_PROFILE_MISMATCH=1"
    echo "  (add to your WM autostart / session env), then restart the session."
    return 1
  fi
  mkdir -p "$DROPIN_DIR"
  {
    echo "# Managed by io.github.p3lu.video-background (bin/video-hwaccel.sh --apply)."
    echo "# Injects Qt FFmpeg hardware-decode settings into the WM session so"
    echo "# quickshell (video wallpaper) decodes on the GPU. Idempotent."
    echo "[Service]"
    echo "EnvironmentFile=-${ENV_FILE}"
  } > "$DROPIN_FILE"
  systemctl --user daemon-reload
  echo "video-hwaccel: drop-in written to $DROPIN_FILE"
  echo "video-hwaccel: daemon-reloaded. Takes effect at next session restart"
  echo "video-hwaccel: (log out / in, or: systemctl --user restart '${wm_unit}')."
  echo "video-hwaccel: current session is unaffected (it already has its env)."
}

# --- user-control helpers -----------------------------------------------------
set_backend() {
  # Force a backend by writing the user override file, then apply.
  local b="${1:-}"
  case "$b" in
    cuda|vaapi|cpu) ;;
    *) echo "video-hwaccel: --set-backend expects cuda | vaapi | cpu (got: $b)"; return 2 ;;
  esac
  mkdir -p "$(dirname "$OVERRIDE_FILE")"
  {
    echo "# User override for video-background GPU acceleration."
    echo "# Managed by: video-hwaccel.sh --set-backend ${b}"
    echo "# Edit freely (KEY=VALUE lines are injected into the session). Remove"
    echo "# this file (or run: video-hwaccel.sh --auto) to re-enable auto-detection."
    if [[ $b == "cuda" ]]; then
      echo "QT_FFMPEG_DECODING_HW_DEVICE_TYPES=cuda"
    elif [[ $b == "vaapi" ]]; then
      echo "QT_FFMPEG_DECODING_HW_DEVICE_TYPES=vaapi"
      echo "QT_FFMPEG_HW_ALLOW_PROFILE_MISMATCH=1"
    else
      # cpu: no env lines -> Qt's CPU default.
      echo "# (no env vars -> CPU decode)"
    fi
  } > "$OVERRIDE_FILE"
  echo "video-hwaccel: override written to $OVERRIDE_FILE (backend=${b})"
}

show_status() {
  echo "=== video-hwaccel status ==="
  echo "  override file: ${OVERRIDE_FILE}"
  if [[ -f $OVERRIDE_FILE ]]; then
    echo "    exists:  YES (auto-detection BYPASSED)"
    sed 's/^/    |     /' "$OVERRIDE_FILE"
  else
    echo "    exists:  no (auto-detection active)"
  fi
  echo "  auto-detected backend: ${auto_backend}"
  if [[ $override_active == true ]]; then
    echo "  effective backend:     ${backend} (USER OVERRIDE)"
  else
    echo "  effective backend:     ${backend} (auto)"
  fi
  echo "  env file:              ${ENV_FILE}"
  if [[ -f $ENV_FILE ]]; then sed 's/^/    |     /' "$ENV_FILE"; fi
  echo "  drop-in:               ${DROPIN_FILE}"
  if [[ -f $DROPIN_FILE ]]; then
    echo "    exists:  YES (session env will be set at next session start)"
  else
    echo "    exists:  no (session runs on Qt default)"
  fi
}

# --- dispatch -----------------------------------------------------------------
case "${1:-}" in
  --apply)
    apply_dropin
    ;;
  --set-backend)
    set_backend "${2:-}"
    # Re-resolve (detection already ran above; override is now in place).
    if [[ -f $OVERRIDE_FILE ]]; then
      override_active=true
      override_env_body="$(grep -vE '^[[:space:]]*(#|$)' "$OVERRIDE_FILE" || true)"
      if [[ -n $override_env_body ]]; then
        env_body="$override_env_body"
        _dt="$(grep -E '^QT_FFMPEG_DECODING_HW_DEVICE_TYPES=' <<<"$override_env_body" | head -1 || true)"
        if   [[ $_dt == *cuda* ]];  then backend="cuda"
        elif [[ $_dt == *vaapi* ]]; then backend="vaapi"
        else backend="cpu"; fi
      else
        env_body="# user override forced CPU decode (no env vars)"; backend="cpu"
      fi
      printf '%s\n' "$env_body" > "$ENV_FILE"
    fi
    apply_dropin
    ;;
  --auto)
    if [[ -f $OVERRIDE_FILE ]]; then
      rm -f "$OVERRIDE_FILE"
      echo "video-hwaccel: removed override ($OVERRIDE_FILE); re-enabling auto-detection."
      override_active=false
    else
      echo "video-hwaccel: no override present; auto-detection already active."
    fi
    apply_dropin
    ;;
  --status)
    show_status
    ;;
  "")
    : # detection-only (env + log already written above)
    ;;
  *)
    echo "usage: video-hwaccel.sh [--apply | --status | --set-backend {cuda|vaapi|cpu} | --auto]"
    exit 2
    ;;
esac

exit 0
