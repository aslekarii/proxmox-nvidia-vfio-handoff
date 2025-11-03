# Proxmox NVIDIA VFIO Handoff

Seamless NVIDIA GPU hot handoff between Proxmox host and VM — bind/unbind nvidia ⇆ vfio-pci safely, no reboots.

---

## 🚀 Overview

This project provides a **production-grade shell script** and an optional Proxmox **hook integration** that allows you to safely and cleanly switch your NVIDIA GPU between the **host** and a **virtual machine** without rebooting. It performs a reliable driver handoff between `nvidia` and `vfio-pci`, ensuring your GPU can be used for both host compute and passthrough workloads.

It eliminates the single biggest limitation of one-GPU Proxmox systems.

Tested on **Proxmox VE 9.x** with **kernel 6.14.11‑4‑pve** and latest NVIDIA drivers.

---

## ⚙️ Features

* Hot NVIDIA ⇆ VFIO driver rebinding (host ↔ VM)
* Automatic framebuffer detachment (prevents console locks)
* Restores host console when VM stops
* Hook-based automation tied to VM lifecycle
* Logging for all handoff phases
* Safe, idempotent, timeboxed operations
* Works with single or multi‑GPU setups

---

## 🧩 Installation

### 1. Download and install the handoff script

```bash
wget -O /usr/local/bin/gpu-handoff.sh \
  https://raw.githubusercontent.com/ComicBit/proxmox-nvidia-vfio-handoff/main/gpu-handoff.sh
sudo chmod +x /usr/local/bin/gpu-handoff.sh
```

This script handles all driver rebinding logic — unloading NVIDIA modules, attaching/detaching `vfio-pci`, resetting the device, and restoring console control.

### 2. Create the Proxmox VM hook script

Create the hook that automatically flips the GPU during VM lifecycle events:

```bash
sudo nano /var/lib/vz/snippets/vm111-hook.sh
```

Paste this content:

```bash
#!/usr/bin/env bash
set -euo pipefail
VMID="$1"; PHASE="$2"
LOG_TAG="[vm${VMID}-hook]"

case "$PHASE" in
  pre-start)
    echo "$LOG_TAG handoff → vfio"
    /usr/local/bin/gpu-handoff.sh to_vfio
    ;;
  post-stop)
    echo "$LOG_TAG handoff → nvidia"
    /usr/local/bin/gpu-handoff.sh to_nvidia
    ;;
  *) ;;
esac
```

Then make it executable:

```bash
sudo chmod +x /var/lib/vz/snippets/vm111-hook.sh
```

### 3. Attach hook to your VM config

Edit your VM configuration:

```bash
sudo nano /etc/pve/qemu-server/111.conf
```

Add this line:

```
hookscript: local:snippets/vm111-hook.sh
```

Replace **111** with your actual VMID.

### 4. Rebuild initramfs (to ensure clean module state)

```bash
sudo update-initramfs -u
```

---

## 🧱 Configuration sanity check

Driver conflicts can arise from leftover modprobe configs (`nvidia.conf`, `pve-blacklist.conf`, etc.).

Before use, review [**BLACKLISTS.md**](./BLACKLISTS.md) — it explains how to clean and standardize `/etc/modprobe.d/` rules for consistent NVIDIA/VFIO behavior.

---

## 🧠 How it works

### Host boot

The host owns the GPU; NVIDIA modules (`nvidia`, `nvidia_drm`, `nvidia_modeset`, `nvidia_uvm`) load to provide console and CUDA access.

### VM start

The hook calls:

```bash
/usr/local/bin/gpu-handoff.sh to_vfio
```

The script:

* Stops NVIDIA daemons (`persistenced`, `mps`)
* Detaches fbcon/DRM devices
* Unloads NVIDIA modules
* Binds GPU + HDMI audio to `vfio-pci`
* Launches the VM

### VM stop

When the VM shuts down, the hook calls:

```bash
/usr/local/bin/gpu-handoff.sh to_nvidia
```

It then:

* Unbinds devices from `vfio-pci`
* Reloads NVIDIA modules
* Rebinds to `nvidia` and `snd_hda_intel`
* Restores host console access

### Lifecycle integration

The hook manages these transitions automatically, ensuring that CPU pinning and driver timing stay in sync with Proxmox events.

---

## 🔍 Status check

You can check binding status anytime:

```bash
/usr/local/bin/gpu-handoff.sh status
```

Examples:

```
[gpu-handoff] 0000:05:00.0 driver=nvidia
[gpu-handoff] 0000:05:00.1 driver=snd_hda_intel
```

When VM runs:

```
[gpu-handoff] 0000:05:00.0 driver=vfio-pci
[gpu-handoff] 0000:05:00.1 driver=vfio-pci
```

---

## 🖥️ Monitor behavior

When the VM is **off**, your GPU-connected monitor shows the Proxmox host console (via NVIDIA DRM KMS).
When the VM starts, the monitor switches to the VM’s display output automatically.

---

## 🔧 Requirements

* Proxmox VE 9.x (kernel 6.14.11‑4‑pve)
* NVIDIA drivers ≥ 470 (tested with 580.82.07‑1)
* `vfio-pci` kernel module
* IOMMU enabled (`amd_iommu=on iommu=pt`)
* VM PCIe passthrough for GPU + audio

---

## 🧱 Troubleshooting

* **Device busy errors** — Framebuffer or modprobe residue; see [BLACKLISTS.md](./BLACKLISTS.md).
* **No console after reboot** — Ensure `options nvidia_drm modeset=1` and disable `simpledrm`/`efifb`.
* **VM start hangs** — Check `dmesg` for `vfio` or `nvidia` conflicts.
* **SSH freeze during handoff** — Heavy I/O; run the flip via hook or systemd.

---

## 🧩 Credits

Field-tested on real single-GPU Proxmox setups.
Created and maintained by **ComicBit** (Leandro Piccione) for open-source distribution.

---

## 📜 License

MIT License — free to use, modify, and share.
If this saves you time, star the repo and share it with others.
