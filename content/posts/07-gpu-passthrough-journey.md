---
title: GPU passthrough with libvirt on Fedora Kinoite
---

I spent the last few days getting GPU passthrough working for my VMs. The goal was to experiment with running LLMs and other GPU workloads in isolated environments. I ran into kernel panics, hanging virsh commands, and display manager crashes along the way.

## My setup

- Fedora Kinoite (ostree/bootc-based system)
- NVIDIA RTX 4070 Ti SUPER (discrete GPU)
- Intel UHD Graphics 770 (integrated GPU - initially disabled in BIOS)
- libvirt + QEMU for virtualization

## Finding your GPU details

First, find the PCI address of your GPU:

```
$ lspci | grep -i nvidia
01:00.0 VGA compatible controller: NVIDIA Corporation AD103 [GeForce RTX 4070 Ti SUPER] (rev a1)
01:00.1 Audio device: NVIDIA Corporation AD103 High Definition Audio Controller (rev a1)
```

The PCI address is `01:00.0` for the GPU and `01:00.1` for the audio controller. In sysfs format, these become `0000:01:00.0` and `0000:01:00.1` (add the domain prefix `0000:`).

Next, find the vendor and device IDs:

```
$ lspci -n -s 01:00.0
01:00.0 0300: 10de:2705 (rev a1)
```

The format is `class: vendor:device`. The vendor ID is `10de` (NVIDIA) and the device ID is `2705` (this specific GPU model). You'll use this as `10de 2705` (space-separated) when binding drivers.

## First attempt: Single-GPU passthrough

Single-GPU passthrough works like this:
1. VM starts → unbind GPU from host → pass to VM
2. VM stops → rebind GPU to host

The host display goes completely black while the VM runs because the GPU is gone. You need SSH access to manage anything on the host.

### Problem: virsh nodedev commands hang

My initial libvirt hooks used `virsh nodedev-detach` and `virsh nodedev-reattach`:

```bash
# Using virsh naming format (underscores instead of colons)
virsh nodedev-detach pci_0000_01_00_0
virsh nodedev-detach pci_0000_01_00_1
```

These commands would hang indefinitely when the system was in certain states. No error messages, just infinite waiting.

### Problem: Kernel panics

Trying to unbind the NVIDIA driver while it was still in use caused kernel panics:

```
nvidia 0000:01:00.0: [drm] drm_WARN_ON(!list_empty(&fb->filp_head))
list_del corruption, ffff8b3442b5d310->next is LIST_POISON1
```

The system would become completely unresponsive. SSH would hang. `systemctl restart` commands would freeze.

The display manager needs to be stopped cleanly before unbinding the GPU driver.

## Dual-GPU setup

I had integrated graphics available but disabled in BIOS. After enabling it (look for "Primary Display", "iGPU Multi-Monitor", or "Integrated Graphics"), I had two GPUs:

```bash
$ lspci | grep -i VGA
00:02.0 VGA compatible controller: Intel Corporation Raptor Lake-S GT1 [UHD Graphics 770]
01:00.0 VGA compatible controller: NVIDIA Corporation AD103 [GeForce RTX 4070 Ti SUPER]
```

This solved the display blackout issue. The host uses the Intel iGPU for display while the NVIDIA GPU gets passed to the VM. No need for SSH access anymore, and the driver management is simpler since the host and VM aren't fighting over the same GPU.

The hooks needed to detect dual-GPU mode automatically.

## Problem: Display manager crashes

Even with dual-GPU, SDDM would crash. NVIDIA kernel modules were still loaded while the GPU was passed through to the VM.

When logging in via the iGPU:
1. SDDM starts
2. KWin/Plasma tries to initialize all GPUs
3. Finds `nvidia_drm` module loaded
4. Tries to use the NVIDIA GPU
5. GPU is bound to vfio-pci (in the VM)
6. Session exits with code 4

The fix is to stop SDDM before unbinding the GPU, even with dual-GPU. This cleanly unloads NVIDIA modules, then restart SDDM on the iGPU only.

### Problem: GPU doesn't rebind on VM shutdown

When the VM stopped, the GPU wouldn't automatically rebind to the nvidia driver. Using `new_id` wasn't enough:

```bash
# Registers the ID but doesn't bind the device
echo "10de 2705" > /sys/bus/pci/drivers/nvidia/new_id
```

The `new_id` file tells the driver "you can claim devices with this vendor:device ID", but it doesn't actually bind any specific device to the driver. Explicitly binding the specific PCI device is required:

```bash
echo "0000:01:00.0" > /sys/bus/pci/drivers/nvidia/bind
```

## Using sysfs directly

Since `virsh nodedev-*` commands kept hanging, I switched to direct sysfs manipulation (which is what virsh uses anyway):

```bash
# Unbind from current driver (use your PCI address from lspci)
echo "0000:01:00.0" > /sys/bus/pci/devices/0000:01:00.0/driver/unbind

# Bind to vfio-pci
modprobe vfio-pci
# Tell vfio-pci it can claim this vendor:device ID (use your ID from lspci -n)
echo "10de 2705" > /sys/bus/pci/drivers/vfio-pci/new_id
# The device should automatically bind since it matches the ID

# Later, bind back to nvidia
modprobe nvidia nvidia_modeset nvidia_drm
# Explicitly bind the device (new_id alone doesn't do this reliably)
echo "0000:01:00.0" > /sys/bus/pci/drivers/nvidia/bind
```

This is more reliable - no hanging commands, immediate errors, and works even when libvirt is in a weird state.

## The working solution

### Prerequisites

1. **IOMMU enabled** in kernel (added to my kickstart template):
   ```
   intel_iommu=on iommu=pt
   ```

2. **Secure Boot disabled** in the VM (NVIDIA drivers aren't signed for secure boot)

3. **Both GPUs visible:**
   ```bash
   $ lspci | grep -i VGA  # Should show 2 devices
   ```

### The hook scripts

I created libvirt hooks that automatically handle GPU switching when the VM starts/stops. You'll need to replace the PCI addresses and vendor:device IDs with your own values from the commands above.

**vfio-startup.sh** - When VM starts:
```bash
# Always stop SDDM to cleanly unload nvidia
systemctl stop sddm.service

# Unbind GPU from nvidia via sysfs (replace with your PCI address)
echo "0000:01:00.0" > /sys/bus/pci/devices/0000:01:00.0/driver/unbind

# Unload NVIDIA modules
modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia

# Bind to vfio-pci (replace with your vendor:device ID)
modprobe vfio-pci
echo "10de 2705" > /sys/bus/pci/drivers/vfio-pci/new_id

# If dual-GPU, restart SDDM on iGPU
if [ "$(lspci | grep -c 'VGA')" -gt 1 ]; then
    systemctl start sddm.service
fi
```

**vfio-teardown.sh** - When VM stops:
```bash
# Unbind from vfio-pci (replace with your PCI address)
echo "0000:01:00.0" > /sys/bus/pci/drivers/vfio-pci/unbind
modprobe -r vfio-pci

# Load nvidia modules
modprobe nvidia nvidia_modeset nvidia_drm nvidia_uvm

# Explicitly bind to nvidia driver (replace with your PCI address)
echo "0000:01:00.0" > /sys/bus/pci/drivers/nvidia/bind
```

## Making it optional

Once the hooks were working, every VM with the configured name would trigger GPU passthrough. I couldn't test VMs without it or have multiple VMs running.

I considered using a flag file in `/tmp`, but that seemed like a terrible hack.

Using the VM name as a signal works better. Libvirt hooks receive the VM name as an argument, so I can check for a suffix:

```bash
GUEST_NAME="$1"

# Only run GPU passthrough hooks for VMs with "-gpu" suffix
if [[ "$GUEST_NAME" != *-gpu ]]; then
    exit 0
fi
```

Then in my Makefile:

```makefile
GPU_PASSTHROUGH ?= no

# Append -gpu suffix to VM name if GPU passthrough is enabled
ifeq ($(GPU_PASSTHROUGH),yes)
  VM_NAME_FULL := $(VM_NAME)-gpu
  VIRT_INSTALL_HOSTDEV := --hostdev 0000:01:00.0 --hostdev 0000:01:00.1
else
  VM_NAME_FULL := $(VM_NAME)
  VIRT_INSTALL_HOSTDEV :=
endif
```

The virt-install command uses `$(VIRT_INSTALL_HOSTDEV)` which expands to the hostdev arguments when GPU passthrough is enabled, or empty when it's not.

Now I can choose at VM creation time:

```bash
# Without GPU passthrough
make virt-install
# Creates VM: "fedora-mybox"
# No --hostdev arguments, hooks don't run

# With GPU passthrough
GPU_PASSTHROUGH=yes make virt-install
# Creates VM: "fedora-mybox-gpu"
# Adds: --hostdev 0000:01:00.0 --hostdev 0000:01:00.1
# Hooks detect "-gpu" suffix and run on VM start/stop
```

The Makefile conditionally adds the `--hostdev` arguments to tell libvirt to pass the PCI devices to the VM. The hooks handle unbinding/rebinding the GPU drivers at the right times.

The VM name is self-documenting, there's no state files to manage, and I can have both VMs exist simultaneously.

## What happens now

**Starting a VM with GPU passthrough:**
1. Hook detects dual-GPU mode
2. Stops SDDM
3. Unbinds NVIDIA GPU from nvidia driver
4. Unloads all NVIDIA modules
5. Loads vfio-pci and binds GPU to it
6. Restarts SDDM on iGPU
7. VM starts with full GPU access

**Stopping the VM:**
1. VM releases GPU
2. Hook unbinds from vfio-pci
3. Loads nvidia modules
4. Explicitly binds GPU to nvidia driver
5. NVIDIA GPU is available on host again

## Things to remember

- Dual-GPU setup avoids the host display going black
- Direct sysfs manipulation is more reliable than virsh commands when things go wrong
- Module loading order matters - you can't unload nvidia_drm if nvidia is loaded
- Display manager needs to be stopped to cleanly unload NVIDIA modules
- `new_id` registers a device ID but doesn't bind it - explicit bind is required
- Kernel parameters `intel_iommu=on iommu=pt` are required

The hooks are in my [toolbox repo](https://github.com/shanemcd/toolbox/tree/main/libvirt-hooks) for future reference.
