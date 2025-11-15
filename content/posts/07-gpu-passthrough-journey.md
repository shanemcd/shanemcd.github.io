---
title: GPU passthrough with libvirt on Fedora Kinoite
---

I spent the last few days getting GPU passthrough working for my VMs. The goal was to experiment with running LLMs and other GPU workloads in isolated environments. I ran into kernel panics, hanging virsh commands, and display manager crashes along the way. Here's what I learned.

## My setup

- Fedora Kinoite (ostree/bootc-based system)
- NVIDIA RTX 4070 Ti SUPER (discrete GPU)
- Intel UHD Graphics 770 (integrated GPU)
- libvirt + QEMU for virtualization

## Understanding GPU passthrough

GPU passthrough lets you assign a physical GPU directly to a VM. The VM sees the actual hardware and can install native drivers. This gives near-native performance for GPU workloads.

The basic flow:
1. VM starts → unbind GPU from host driver → bind to vfio-pci → pass to VM
2. VM stops → unbind from vfio-pci → rebind to host driver

The challenges are around timing, driver state, and making sure nothing else is using the GPU during the transition.

## Finding your GPU details

First, find the PCI address of your GPU:

```bash
$ lspci | grep -i nvidia
01:00.0 VGA compatible controller: NVIDIA Corporation AD103 [GeForce RTX 4070 Ti SUPER] (rev a1)
01:00.1 Audio device: NVIDIA Corporation AD103 High Definition Audio Controller (rev a1)
```

The PCI address is `01:00.0` for the GPU and `01:00.1` for the audio controller. In sysfs format, these become `0000:01:00.0` and `0000:01:00.1` (add the domain prefix `0000:`).

Next, find the vendor and device IDs:

```bash
$ lspci -n -s 01:00.0
01:00.0 0300: 10de:2705 (rev a1)
```

The format is `class: vendor:device`. The vendor ID is `10de` (NVIDIA) and the device ID is `2705` (this specific GPU model). You'll use this as `10de 2705` (space-separated) when binding drivers.

## Prerequisites

Before GPU passthrough will work:

1. **IOMMU enabled** in kernel boot parameters:
   ```
   intel_iommu=on iommu=pt
   ```

2. **Secure Boot disabled** in the VM (NVIDIA drivers aren't signed for secure boot in Linux guests)

3. **Dual-GPU recommended**: Having both integrated and discrete GPUs makes this much easier. Enable integrated graphics in BIOS (look for "Primary Display", "iGPU Multi-Monitor", or "Integrated Graphics").

   ```bash
   $ lspci | grep -i VGA
   00:02.0 VGA compatible controller: Intel Corporation Raptor Lake-S GT1 [UHD Graphics 770]
   01:00.0 VGA compatible controller: NVIDIA Corporation AD103 [GeForce RTX 4070 Ti SUPER]
   ```

   With dual-GPU, the host uses Intel iGPU for display while NVIDIA goes to the VM. Single-GPU passthrough is possible but your host display goes completely black while the VM runs.

## The problems I ran into

### Problem 1: virsh nodedev commands hang

My initial hooks used `virsh nodedev-detach` and `virsh nodedev-reattach`. These would hang indefinitely with no error messages when the system was in certain states.

**Solution**: Use direct sysfs manipulation instead. It's more reliable and gives immediate errors.

### Problem 2: Kernel panics

Trying to unbind the NVIDIA driver while it was in use caused kernel panics:

```
nvidia 0000:01:00.0: [drm] drm_WARN_ON(!list_empty(&fb->filp_head))
list_del corruption, ffff8b3442b5d310->next is LIST_POISON1
```

The system would become completely unresponsive.

**Solution**: Stop the display manager cleanly before unbinding the GPU driver, even with dual-GPU. This unloads NVIDIA modules properly.

### Problem 3: Display manager crashes

Even with dual-GPU and SDDM stopped before VM start, sometimes after stopping the VM:
1. SDDM restarts
2. KWin/Plasma tries to initialize all GPUs
3. Finds `nvidia_drm` module loaded
4. Tries to use the NVIDIA GPU before driver is fully ready
5. Session crashes

**Solution**: Manage module loading/unloading carefully in hooks. Explicitly bind devices after loading modules.

### Problem 4: GPU doesn't rebind after VM shutdown

Using `new_id` wasn't enough:

```bash
# Registers the ID but doesn't bind the device
echo "10de 2705" > /sys/bus/pci/drivers/nvidia/new_id
```

The `new_id` file tells the driver "you can claim devices with this vendor:device ID", but it doesn't actually bind any specific device to the driver.

**Solution**: Explicitly bind the specific PCI device:

```bash
echo "0000:01:00.0" > /sys/bus/pci/drivers/nvidia/bind
```

### Problem 5: libvirt managed='yes' hangs everything

This was the root cause of most issues. When you use `--hostdev` with virt-install, libvirt defaults to `managed='yes'`, which means libvirt automatically handles unbinding the device from the host driver and binding it to vfio-pci.

In theory, this should work seamlessly. In practice, on my Fedora system with NVIDIA GPU passthrough, **it hung every single time**. libvirtd would become unresponsive, virsh commands would hang, and eventually zombie processes would pile up.

**Solution**: Use `managed='no'` and handle driver binding entirely in libvirt hooks.

## The working solution

### Direct sysfs manipulation

Since virsh commands kept hanging, I use direct sysfs for all driver operations:

```bash
# Unbind from current driver
echo "0000:01:00.0" > /sys/bus/pci/devices/0000:01:00.0/driver/unbind

# Bind to vfio-pci
modprobe vfio-pci
echo "10de 2705" > /sys/bus/pci/drivers/vfio-pci/new_id

# Later, bind back to nvidia
modprobe nvidia nvidia_modeset nvidia_drm
echo "0000:01:00.0" > /sys/bus/pci/drivers/nvidia/bind
```

This is more reliable - no hanging commands, immediate errors, works even when libvirt is in a weird state.

### Using managed='no'

The problem: virt-install doesn't provide a command-line option to set `managed='no'`. You have to either:
1. Manually edit the XML after creation
2. Use `--print-xml` to generate XML, modify it, then define with virsh

I chose option 2 and automated it with Ansible.

### Ansible automation

I created an Ansible role that:
1. Generates VM XML using `virt-install --print-xml` (doesn't actually create the VM)
2. Modifies the XML to set `managed='no'` on hostdev elements
3. Defines and starts the VM with `virsh`

The key task:

```yaml
- name: Set hostdev managed='no' in XML for GPU passthrough
  community.general.xml:
    path: "/tmp/{{ virt_install_vm_name }}.xml"
    xpath: "//hostdev[@mode='subsystem'][@type='pci']"
    attribute: "managed"
    value: "no"
  when: virt_install_gpu_passthrough | default(false) | bool
```

This completely avoids libvirt's managed mode and all the hanging issues.

### Auto-detecting GPU addresses

Instead of hardcoding PCI addresses, the hooks and Makefile auto-detect the NVIDIA GPU:

```bash
# In the hooks
NVIDIA_VGA=$(lspci -D | grep -i "NVIDIA" | grep -i "VGA" | awk '{print $1}')
NVIDIA_AUDIO=$(lspci -D | grep -i "NVIDIA" | grep -i "Audio" | awk '{print $1}')

# Get vendor:device IDs
NVIDIA_VGA_ID=$(lspci -n -s "$NVIDIA_VGA" | awk '{print $3}')
NVIDIA_VENDOR=$(echo "$NVIDIA_VGA_ID" | cut -d: -f1)
NVIDIA_DEVICE=$(echo "$NVIDIA_VGA_ID" | cut -d: -f2)
```

Note: Using two separate `grep` commands works better than `grep -i "NVIDIA.*VGA"` because lspci output has "Corporation" between "NVIDIA" and "VGA".

In the Makefile:

```makefile
ifeq ($(GPU_PASSTHROUGH),yes)
  # Auto-detect NVIDIA GPU PCI addresses
  NVIDIA_VGA_ADDR := $(shell lspci -D | grep -i "NVIDIA" | grep -i "VGA" | awk '{print $$1}')
  NVIDIA_AUDIO_ADDR := $(shell lspci -D | grep -i "NVIDIA" | grep -i "Audio" | awk '{print $$1}')
  # Error if no NVIDIA GPU found
  ifeq ($(NVIDIA_VGA_ADDR),)
    $(error GPU_PASSTHROUGH=yes but no NVIDIA VGA device found. Check 'lspci | grep -i nvidia')
  endif
endif
```

No more hardcoded addresses - works on any system with an NVIDIA GPU.

### The libvirt hooks

With `managed='no'`, hooks handle ALL driver binding. They auto-detect GPU addresses and handle single vs dual-GPU configurations.

**vfio-startup.sh** - When VM starts:
```bash
#!/bin/bash
set -x

# Auto-detect NVIDIA GPU
NVIDIA_VGA=$(lspci -D | grep -i "NVIDIA" | grep -i "VGA" | awk '{print $1}')
NVIDIA_AUDIO=$(lspci -D | grep -i "NVIDIA" | grep -i "Audio" | awk '{print $1}')

# Get vendor:device IDs
NVIDIA_VGA_ID=$(lspci -n -s "$NVIDIA_VGA" | awk '{print $3}')
NVIDIA_VENDOR=$(echo "$NVIDIA_VGA_ID" | cut -d: -f1)
NVIDIA_DEVICE=$(echo "$NVIDIA_VGA_ID" | cut -d: -f2)

# Count GPUs to detect dual-GPU mode
VGA_COUNT=$(lspci | grep -i "VGA compatible controller" | wc -l)

# Stop SDDM to cleanly unload nvidia
systemctl stop sddm.service
sleep 2

# Unbind GPU from nvidia driver
echo "$NVIDIA_VGA" > /sys/bus/pci/devices/$NVIDIA_VGA/driver/unbind 2>/dev/null || true
if [ -n "$NVIDIA_AUDIO" ]; then
    echo "$NVIDIA_AUDIO" > /sys/bus/pci/devices/$NVIDIA_AUDIO/driver/unbind 2>/dev/null || true
fi

# Unload NVIDIA modules
modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia i2c_nvidia_gpu 2>/dev/null || true

# Load vfio-pci and bind GPU
modprobe vfio-pci
echo "$NVIDIA_VENDOR $NVIDIA_DEVICE" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || true
if [ -n "$NVIDIA_AUDIO" ]; then
    NVIDIA_AUDIO_DEVICE=$(echo "$(lspci -n -s "$NVIDIA_AUDIO" | awk '{print $3}')" | cut -d: -f2)
    echo "$NVIDIA_VENDOR $NVIDIA_AUDIO_DEVICE" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || true
fi

# If dual-GPU, restart SDDM on iGPU
if [ "$VGA_COUNT" -gt 1 ]; then
    systemctl start sddm.service
fi
```

**vfio-teardown.sh** - When VM stops:
```bash
#!/bin/bash
set -x

# Auto-detect NVIDIA GPU
NVIDIA_VGA=$(lspci -D | grep -i "NVIDIA" | grep -i "VGA" | awk '{print $1}')
NVIDIA_AUDIO=$(lspci -D | grep -i "NVIDIA" | grep -i "Audio" | awk '{print $1}')

# Get vendor:device IDs
NVIDIA_VGA_ID=$(lspci -n -s "$NVIDIA_VGA" | awk '{print $3}')
NVIDIA_VENDOR=$(echo "$NVIDIA_VGA_ID" | cut -d: -f1)
NVIDIA_DEVICE=$(echo "$NVIDIA_VGA_ID" | cut -d: -f2)

VGA_COUNT=$(lspci | grep -i "VGA compatible controller" | wc -l)

# Remove GPU from vfio-pci
echo "$NVIDIA_VENDOR $NVIDIA_DEVICE" > /sys/bus/pci/drivers/vfio-pci/remove_id 2>/dev/null || true
if [ -n "$NVIDIA_AUDIO" ]; then
    NVIDIA_AUDIO_DEVICE=$(echo "$(lspci -n -s "$NVIDIA_AUDIO" | awk '{print $3}')" | cut -d: -f2)
    echo "$NVIDIA_VENDOR $NVIDIA_AUDIO_DEVICE" > /sys/bus/pci/drivers/vfio-pci/remove_id 2>/dev/null || true
fi

echo "$NVIDIA_VGA" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
if [ -n "$NVIDIA_AUDIO" ]; then
    echo "$NVIDIA_AUDIO" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
fi

# Unload vfio-pci
modprobe -r vfio-pci 2>/dev/null || true

# Load nvidia modules and bind GPU
modprobe nvidia nvidia_modeset nvidia_drm nvidia_uvm i2c_nvidia_gpu
echo "$NVIDIA_VGA" > /sys/bus/pci/drivers/nvidia/bind 2>/dev/null || true
if [ -n "$NVIDIA_AUDIO" ]; then
    echo "$NVIDIA_AUDIO" > /sys/bus/pci/drivers/snd_hda_intel/bind 2>/dev/null || true
fi

sleep 2

# Only restart SDDM if single-GPU (it was stopped during startup)
if [ "$VGA_COUNT" -eq 1 ]; then
    # Rebind framebuffer and consoles
    echo efi-framebuffer.0 > /sys/bus/platform/drivers/efi-framebuffer/bind 2>/dev/null || true
    echo 1 > /sys/class/vtconsole/vtcon0/bind 2>/dev/null || true
    echo 1 > /sys/class/vtconsole/vtcon1/bind 2>/dev/null || true
    sleep 2
    systemctl start sddm.service
fi
```

**qemu** - Main hook file that calls startup/teardown:
```bash
#!/bin/bash

GUEST_NAME="$1"
OPERATION="$2"

# Only run for VMs with "-gpu" suffix
if [[ "$GUEST_NAME" != *-gpu ]]; then
    exit 0
fi

HOOK_DIR="$(dirname "$0")"

if [ "$OPERATION" = "prepare" ] || [ "$OPERATION" = "start" ]; then
    "$HOOK_DIR/vfio-startup.sh"
elif [ "$OPERATION" = "release" ] || [ "$OPERATION" = "stopped" ]; then
    "$HOOK_DIR/vfio-teardown.sh"
fi
```

### Making it optional

Using the VM name as a signal: VMs with `-gpu` suffix get GPU passthrough, others don't.

In the Makefile:

```makefile
GPU_PASSTHROUGH ?= no

ifeq ($(GPU_PASSTHROUGH),yes)
  VM_NAME_FULL := $(VM_NAME)-gpu
  NVIDIA_VGA_ADDR := $(shell lspci -D | grep -i "NVIDIA" | grep -i "VGA" | awk '{print $$1}')
  NVIDIA_AUDIO_ADDR := $(shell lspci -D | grep -i "NVIDIA" | grep -i "Audio" | awk '{print $$1}')
else
  VM_NAME_FULL := $(VM_NAME)
endif
```

Now I can choose at VM creation time:

```bash
# Without GPU passthrough
make virt-install

# With GPU passthrough
GPU_PASSTHROUGH=yes make virt-install
```

The Makefile passes the GPU addresses to Ansible, which builds the VM XML with hostdev entries and `managed='no'`. The hooks detect the `-gpu` suffix and handle driver binding.

### Keeping SPICE graphics

You can have both a virtual display (SPICE/QXL) AND the passed-through NVIDIA GPU. The VM sees both displays.

```bash
virt-install \
  --graphics spice \
  --video qxl \
  --hostdev 0000:01:00.0 \
  --hostdev 0000:01:00.1 \
  --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no
```

This gives you:
- SPICE access via virt-viewer (for remote management)
- Physical monitor output via NVIDIA GPU (for primary use)
- Flexibility to use either display

## The complete workflow

```bash
# Create VM with GPU passthrough
GPU_PASSTHROUGH=yes make virt-install
```

This:
1. Auto-detects NVIDIA GPU addresses
2. Runs Ansible playbook to generate XML with `managed='no'`
3. Defines and starts the VM
4. Hooks handle driver binding when VM starts/stops

**Starting a VM with GPU passthrough:**
1. Hook detects dual-GPU mode
2. Stops SDDM
3. Unbinds NVIDIA GPU from nvidia driver
4. Unloads all NVIDIA modules
5. Loads vfio-pci and binds GPU to it
6. Restarts SDDM on iGPU (dual-GPU only)
7. VM starts with full GPU access

**Stopping the VM:**
1. VM releases GPU
2. Hook unbinds from vfio-pci
3. Loads nvidia modules
4. Explicitly binds GPU to nvidia driver
5. NVIDIA GPU is available on host again
6. Restarts SDDM (single-GPU only)

## Results

After implementing the `managed='no'` approach:

- ✅ VM creation completes without hanging
- ✅ libvirtd stays responsive
- ✅ GPU switches between host and VM seamlessly
- ✅ Display manager handles transitions cleanly
- ✅ No hardcoded PCI addresses
- ✅ No manual XML editing required
- ✅ Can toggle GPU passthrough with a single environment variable

## Troubleshooting

### GPU won't rebind to nvidia after VM shutdown

If the GPU is stuck in an unbound state, you'll see no driver:

```bash
$ lspci -nnk -s 01:00.0
01:00.0 VGA compatible controller [0300]: NVIDIA Corporation AD103 [GeForce RTX 4070 Ti SUPER] [10de:2705] (rev a1)
	Subsystem: PNY Device [196e:141c]
	Kernel modules: nouveau, nvidia_drm, nvidia
# Notice: no "Kernel driver in use" line
```

The device is disabled and nvidia won't bind:

```bash
$ sudo sh -c 'echo "0000:01:00.0" > /sys/bus/pci/drivers/nvidia/bind'
sh: line 1: echo: write error: No such device
```

**Solution**: Remove and re-scan the PCI device:

```bash
sudo sh -c 'echo "1" > /sys/bus/pci/devices/0000:01:00.0/remove'
sudo sh -c 'echo "1" > /sys/bus/pci/rescan'
sleep 2
lspci -nnk -s 01:00.0  # Verify it's bound to nvidia
```

### libvirtd hangs or becomes unresponsive

Usually because:
1. GPU is in a bad state (not bound to any driver)
2. Hooks ran but VM never started
3. libvirt is waiting for stuck resources

**Solution**:
1. Cancel hung commands (Ctrl+C)
2. Run teardown hook manually: `sudo /etc/libvirt/hooks/vfio-teardown.sh`
3. If GPU still won't bind, use PCI remove/rescan above
4. Kill zombie processes: `sudo killall -9 libvirtd`
5. Restart: `sudo systemctl restart libvirtd`

## Key lessons

- **libvirt's managed mode doesn't work reliably** with NVIDIA GPU passthrough on my system - use `managed='no'`
- **Direct sysfs manipulation** is more reliable than virsh commands
- **Display manager must be stopped** before unbinding GPU drivers to avoid kernel panics
- **Module loading order matters** - can't unload nvidia_drm if nvidia is loaded
- **`new_id` registers but doesn't bind** - explicit bind is required
- **Auto-detection** makes the setup portable across systems
- **VM naming convention** (suffix) is better than flag files for conditional behavior

The hooks are in my [toolbox repo](https://github.com/shanemcd/toolbox/tree/main/libvirt-hooks) for reference.
