---
title: Dealing with dual-GPU display issues on KDE Plasma
---

A few months ago I wrote about [[04-jetkvm-tailscale|Getting Tailscale to work on my JetKVM]]. I had been using it as a remote desktop solution by connecting it to the HDMI port on my NVIDIA GPU. It worked fine, but when I started working on [[07-gpu-passthrough-journey|GPU passthrough]], I realized I'd lose all graphics when passing the NVIDIA GPU to a VM.

The solution was to enable the integrated graphics in my BIOS and move the JetKVM to the motherboard's HDMI port. This way I could still access the system remotely (and reach BIOS) even when the NVIDIA GPU was assigned to a VM.

What I didn't anticipate was that having displays connected to both GPUs would cause some strange issues with KDE Plasma.

## My setup

- Fedora Kinoite (Wayland + Plasma 6)
- NVIDIA RTX 4070 Ti SUPER (discrete GPU)
- Intel UHD Graphics 770 (integrated GPU)
- Samsung Odyssey G70NC (4K @ 144 Hz) connected to NVIDIA DisplayPort
- JetKVM connected to motherboard's HDMI port (Intel iGPU)

The JetKVM lets you choose from a selection of different EDID options. I'm using "DELL D2721H, 1920x1080" which has worked well for my setup.

## The problems

After moving the JetKVM to the Intel iGPU's HDMI port, I started running into two separate issues.

### Problem 1: DisplayPort won't wake up

My primary monitor started having issues after waking from sleep:

- Turn on briefly, then go black and repeat this cycle indefinitely
- Wake up stuck at 640×480 resolution
- Lose all refresh rate options above 60 Hz

This was frustrating because nothing about the monitor, cable, or GPU had changed. The first few times it happened I rebooted and everything went back to normal, but I knew something was wrong with the display detection.

#### Troubleshooting

The first thing I checked was whether this was a hardware issue. I looked at `/sys/class/drm/card0-HDMI-A-2/modes` to see what display modes the kernel was detecting:

```
3840x2160
2560x1440
1920x1080
...
640x480
```

When things were working correctly, this file would have entries like `3840x2160@144` and other high refresh rate modes. When broken, all the high refresh modes were just... gone.

This told me the EDID wasn't being read correctly - the driver was falling back to some safe default mode list.

I tried a bunch of things that didn't work:
- Switching between different resolution/refresh rate combinations in Plasma's settings
- Unplugging and replugging the monitor
- Disabling and re-enabling displays in `kscreen-doctor`

Sometimes switching from 4K@60 to 4K@120 would "kick" things back into working, but it was unreliable.

After digging through forums and bug reports, I realized this was a DisplayPort link training issue. When waking from sleep, the DisplayPort connection wasn't renegotiating properly - the EDID read would fail and the driver would fall back to safe modes like 640×480.

I found that forcing a known stable mode would reset the stuck state:

```bash
kscreen-doctor output.2.mode.3840x2160@60
sleep 2
kscreen-doctor output.2.mode.3840x2160@143.99
```

This worked as a workaround, but I shouldn't have to run commands manually every time the monitor wakes up.

Eventually I just switched to an HDMI 2.1 cable and the wake issues disappeared entirely. HDMI 2.1 handles the link negotiation much more reliably than DisplayPort on my setup.

### Problem 2: DPI scaling issues

After switching to HDMI, I noticed something else: my Samsung display looked... off. Text seemed larger than it should be, and when I checked the display settings, I realized KDE was scaling everything to match the DPI across both displays.

The JetKVM at 1080p has a much lower DPI than my 4K Samsung. KDE was using the lower DPI as the baseline, which made everything on my Samsung look less sharp than it should.

## The solution

I didn't need both displays active all the time. The JetKVM is only useful when I need remote access to the system or BIOS. The rest of the time, I want just my Samsung display running at full quality.

What I needed was a way to easily toggle the JetKVM display on and off from SSH.

## The script

I put together a script that auto-detects the JetKVM by reading EDID data from `/sys/class/drm/` and uses `kscreen-doctor` to toggle it.

The tricky part is that `kscreen-doctor` needs access to the Wayland session, which isn't normally available over SSH or a TTY. The script handles this by setting up the necessary environment variables to communicate with the running Plasma session.

```bash
#!/usr/bin/env bash

# jetkvm-display: enable/disable the JetKVM HDMI output in a KDE Wayland session.
# Usage: jetkvm-display enable
#        jetkvm-display disable

set -euo pipefail

# Unique EDID substring for the JetKVM monitor
JETKVM_EDID_TAG="DELL D2721H"

export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
export QT_QPA_PLATFORM="wayland"

# Make sure sudo can prompt once if needed (for reading EDID)
sudo -v >/dev/null 2>&1 || true

# Run kscreen-doctor inside the active KDE Wayland session
ks_doctor() {
  kscreen-doctor "$@"
}

# Find the HDMI connector whose EDID contains the JetKVM tag
find_jetkvm_connector() {
  local f basename connector
  for f in /sys/class/drm/*HDMI-A-*/edid; do
    [ -r "$f" ] || continue
    if sudo strings "$f" 2>/dev/null | grep -q "${JETKVM_EDID_TAG}"; then
      basename="$(basename "$(dirname "$f")")"   # e.g. card0-HDMI-A-1
      connector="${basename#*-}"                 # strip "card0-" -> HDMI-A-1
      echo "${connector}"
      return 0
    fi
  done
  return 1
}

# Verify that kscreen-doctor knows about this connector name
detect_jetkvm_output_name() {
  local connector="$(
    find_jetkvm_connector || {
      echo "jetkvm-display: EDID tag '${JETKVM_EDID_TAG}' not found on any HDMI connector" >&2
      return 1
    }
  )"

  # Check that kscreen-doctor -o lists an Output with that name
  if ! ks_doctor -o | awk -v conn="$connector" '
      /Output:/ {
        # "Output: 2 HDMI-A-1 <uuid>"
        name = $3
        if (name == conn) {
          found = 1
        }
      }
      END { exit (!found) }
    '; then
    echo "jetkvm-display: found connector '${connector}' for JetKVM, but no matching Output name in kscreen-doctor -o" >&2
    echo "jetkvm-display: Outputs seen:" >&2
    ks_doctor -o | grep 'Output:' >&2 || true
    return 1
  fi

  echo "jetkvm-display: JetKVM detected on connector '${connector}'" >&2
  echo "${connector}"
}

JET_OUTPUT_NAME="$(detect_jetkvm_output_name || true)"

if [ -z "${JET_OUTPUT_NAME}" ]; then
  echo "jetkvm-display: could not auto-detect JetKVM" >&2
  exit 1
fi

do_enable() {
  ks_doctor "output.${JET_OUTPUT_NAME}.enable"
}

do_disable() {
  ks_doctor "output.${JET_OUTPUT_NAME}.disable"
}

case "${1:-}" in
  enable)
    do_enable
    ;;
  disable)
    do_disable
    ;;
  *)
    echo "Usage: $0 {enable|disable}" >&2
    exit 1
    ;;
esac
```

I saved this to `~/.local/bin/jetkvm-display` and made it executable.

Now when I need remote access:

```bash
ssh desktop
jetkvm-display enable
# Access the system through JetKVM
jetkvm-display disable
```

The key things this script does:
- Reads EDID data from `/sys/class/drm/` to find which HDMI connector has the JetKVM (searches for "DELL D2721H")
- Verifies that `kscreen-doctor` knows about that connector
- Sets up the necessary environment variables (`XDG_RUNTIME_DIR`, `WAYLAND_DISPLAY`, `DBUS_SESSION_BUS_ADDRESS`) to talk to the Wayland session from SSH
- Uses `kscreen-doctor` to cleanly enable/disable the display

## Results

With the JetKVM display disabled by default:
- No wake issues (after switching to HDMI 2.1)
- No DPI scaling problems
- Samsung runs at full 4K @ 143.99 Hz
- I can still enable the JetKVM whenever I need remote access

Switching from DisplayPort to HDMI 2.1 completely resolved the wake issues. Combined with keeping the JetKVM display disabled when not in use, everything has been stable since.
