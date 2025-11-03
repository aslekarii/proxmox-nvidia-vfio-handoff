#!/usr/bin/env bash
# gpu-handoff.sh — robust NVIDIA <-> vfio-pci binder for Proxmox hosts
# - Discovers the primary NVIDIA GPU and its HDA function from sysfs
# - Idempotent bind/unbind with retries + FLR on EBUSY
# - Leaves driver_override empty after success to avoid sticky binds
# - Minimal stopping of host consumers to prevent races/hangs
#
# Usage:
#   gpu-handoff.sh status
#   gpu-handoff.sh to_vfio
#   gpu-handoff.sh to_nvidia
#   gpu-handoff.sh handoff <vfio|nvidia>
#
# Optional: space-separated CTIDs to restart after flips (e.g., containers using CUDA)
#   export LXC_RESTART_IDS="107 115"

set -u
umask 022

log() { echo "[gpu-handoff] $*" >&2; }
die() { echo "[gpu-handoff][ERROR] $*" >&2; exit 1; }

# ---------- Device discovery (sysfs only, no lspci) ----------
# Pick first NVIDIA VGA controller as GPU, and sibling .1 HDA if present
discover_gpu() {
  local dev
  for dev in /sys/bus/pci/devices/*; do
    [[ -e "$dev" ]] || continue
    # class 0x0300xx is VGA; vendor 0x10de is NVIDIA
    if [[ -f "$dev/vendor" && -f "$dev/class" ]]; then
      local v=$(<"$dev/vendor") c=$(<"$dev/class")
      if [[ "$v" == "0x10de" && "${c:0:6}" == "0x0300" ]]; then
        GPU=$(basename "$dev")
        break
      fi
    fi
  done
  [[ -n "${GPU:-}" ]] || die "no NVIDIA GPU found"

  # Try sibling audio function (same slot .1), else empty
  local base="${GPU%.*}"
  if [[ -e "/sys/bus/pci/devices/${base}.1" ]]; then
    AUD="${base}.1"
  else
    AUD=""
  fi
}

read_driver() {  # $1=BDF -> prints driver or empty
  local d="/sys/bus/pci/devices/$1/driver"
  [[ -L "$d" ]] && basename "$(readlink -f "$d")" || true
}

set_override() {  # $1=BDF $2=driver-name-or-empty
  local f="/sys/bus/pci/devices/$1/driver_override"
  [[ -f "$f" ]] || return 0
  printf '%s' "${2:-}" > "$f"
}

flr_reset() {  # $1=BDF — best effort function-level reset
  local dev="/sys/bus/pci/devices/$1"
  [[ -w "$dev/reset" ]] && echo 1 > "$dev/reset" || true
}

unbind_if_bound() {  # $1=BDF
  local cur; cur="$(read_driver "$1")"
  [[ -z "$cur" ]] && return 0
  echo "$1" > "/sys/bus/pci/drivers/$cur/unbind"
}

bind_to() {  # $1=BDF $2=driver (nvidia|vfio-pci|snd_hda_intel)
  local bdf="$1" want="$2" tries=0 err
  local cur; cur="$(read_driver "$bdf")"
  [[ "$cur" == "$want" ]] && { set_override "$bdf" ""; return 0; }

  # Some kernels require override to match target for bind to succeed
  set_override "$bdf" "$want"
  [[ -n "$cur" ]] && unbind_if_bound "$bdf"

  while (( tries < 12 )); do
    if echo "$bdf" > "/sys/bus/pci/drivers/$want/bind" 2> >(cat >&3); then
      set_override "$bdf" ""  # prevent sticky future binds
      return 0
    fi
    err="$(cat <&3 2>/dev/null || true)"
    if echo "$err" | grep -qi 'device or resource busy'; then
      flr_reset "$bdf"
    fi
    sleep 0.25
    ((tries++))
  done

  log "bind_to $bdf -> $want failed"
  [[ -n "$err" ]] && echo "$err" >&2
  return 1
} 3>/tmp/.gpu_bind_err.$$; trap 'rm -f /tmp/.gpu_bind_err.$$' EXIT

fbcon_detach_best_effort() {
  for c in /sys/class/vtconsole/vtcon*; do
    [[ -w "$c/bind" ]] && echo 0 > "$c/bind" 2>/dev/null || true
  done
}

stop_host_consumers() {
  # Keep it light; persistenced & MPS only (biggest offenders). Best-effort.
  systemctl stop nvidia-persistenced 2>/dev/null || true
  pkill -9 -f nvidia-cuda-mps-server 2>/dev/null || true
}

start_persistenced_opt() {
  # Enable if you like persistence; otherwise leave disabled for cleanliness.
  # systemctl start nvidia-persistenced 2>/dev/null || true
  true
}

restart_lxcs_opt() {
  local id
  for id in ${LXC_RESTART_IDS:-}; do
    pct restart "$id" 2>/dev/null || true
  done
}

# ---------- Actions ----------
do_status() {
  discover_gpu
  log "$GPU driver=$(read_driver "$GPU")"
  if [[ -n "$AUD" ]]; then
    log "$AUD driver=$(read_driver "$AUD")"
  fi
}

to_vfio() {
  discover_gpu
  log "handoff -> vfio-pci"
  stop_host_consumers
  fbcon_detach_best_effort

  bind_to "$GPU" vfio-pci || die "failed to bind $GPU to vfio-pci"
  [[ -n "$AUD" ]] && bind_to "$AUD" vfio-pci || true

  restart_lxcs_opt
  log "ok: $GPU=$(read_driver "$GPU") ${AUD:+$AUD=$(read_driver "$AUD")}"
}

to_nvidia() {
  discover_gpu
  log "handoff -> nvidia"

  # Ensure stack loaded (order matters minimally here)
  modprobe nvidia || die "failed to load nvidia"
  modprobe nvidia_uvm 2>/dev/null || true
  modprobe nvidia_modeset 2>/dev/null || true
  modprobe nvidia_drm 2>/dev/null || true

  # Rebind; helpers handle FLR+retries+override cleanup
  bind_to "$GPU" nvidia || die "failed to bind $GPU to nvidia"
  [[ -n "$AUD" ]] && bind_to "$AUD" snd_hda_intel || true

  start_persistenced_opt
  restart_lxcs_opt
  log "ok: $GPU=$(read_driver "$GPU") ${AUD:+$AUD=$(read_driver "$AUD")}"
}

do_handoff() {
  case "${1:-}" in
    vfio) to_vfio ;;
    nvidia) to_nvidia ;;
    *) die "handoff expects 'vfio' or 'nvidia'" ;;
  esac
}

# ---------- Entry ----------
cmd="${1:-status}"
case "$cmd" in
  status)    do_status ;;
  to_vfio)   to_vfio ;;
  to_nvidia) to_nvidia ;;
  handoff)   shift; do_handoff "${1:-}" ;;
  *) die "unknown command: $cmd" ;;
esac
