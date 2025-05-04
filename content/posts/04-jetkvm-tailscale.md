---
title: Getting Tailscale to work on my JetKVM
updated: 05-01-2025
---

Earlier this week I got my [JetKVM](https://jetkvm.com) in the mail. There's plenty of posts out there about how awesome it is, so I won't bother to write another post reiterating that. Well, maybe briefly: it is in fact awesome. You should by one.

## Remotely accessing my JetKVM

While the folks behind this product seem smart enough, I'm always skeptical about using new cloud services, especially when they have a direct line to my PC. Rather than use their [Remote Access](https://jetkvm.com/docs/networking/remote-access) feature, I was happy to see that they also had a link in their FAQ pointing to an article on Medium called [Installing Tailscale on JetKVM](https://medium.com/@brandontuttle/installing-tailscale-on-a-jetkvm-3c72355b7eb0). This unfortunately did not work for me without some minor tweaks.

### Getting Tailscale to start automatically

Because JetKVM is built on top of busybox (for better or worse - worse IMHO), it lacks a modern init system. Other than being a good introduction for less experienced folks into how things used to be before systemd, it is a bit of a pain to work with.

Anyway, after using the script shared in the Medium post linked above, the first thing I noticed was that upon reboot my device did not rejoin my tailnet.

After adding some basic logging to the init script, I was able to see that it was crashing due to the TUN device not being available:

```
wgengine.NewUserspaceEngine(tun "tailscale0") error: tstun.New("tailscale0"): CreateTUN("tailscale0") failed; /dev/net/tun does not exist
flushing log.
logger closing down
logtail: upload: log upload of 942 bytes compressed failed: Post "https://log.tailscale.com/c/tailnode.log.tailscale.io/986ca5896dc4d4b0b3de7618f45bf030588040a882f53c226de82ebe42fc0c5f": context canceled
logtail: dial "log.tailscale.com:443" failed: dial tcp: lookup log.tailscale.com: operation was canceled (in 1.022s), trying bootstrap...
getLocalBackend error: createEngine: tstun.New("tailscale0"): CreateTUN("tailscale0") failed; /dev/net/tun does not exist
```

Strangely, simply re-running this script resolved the issue and Tailscale started fine. This led me to the realization that the `tun` kernel module needed to be loaded ahead of time.

Here is my version of the init script that adds some basic logging and checks and ensures that `/dev/net/tun` exists before trying to start `tailscaled`:

```bash
#!/bin/sh
log="/tmp/ts.log"

echo "$(date): S22tailscale script starting with arg: $1" >> $log

wait_for_tun() {
  modprobe tun 2>>$log
  for i in $(seq 1 10); do
    [ -e /dev/net/tun ] && return 0
    echo "$(date): /dev/net/tun not ready, retrying..." >> $log
    sleep 1
  done
  echo "$(date): /dev/net/tun still not present after waiting" >> $log
  return 1
}

wait_for_network() {
  for i in $(seq 1 10); do
    ip route | grep default >/dev/null && return 0
    echo "$(date): no default route yet, retrying..." >> $log
    sleep 1
  done
  echo "$(date): still no default route after waiting" >> $log
  return 1
}

case "$1" in
  start)
    wait_for_tun || exit 1
    wait_for_network || exit 1
    echo "$(date): Starting tailscaled..." >> $log
    TS_DEBUG_FIREWALL_MODE=nftables /userdata/tailscale/tailscaled \
      -statedir /userdata/tailscale-state >> $log 2>&1 &
    ;;
  stop)
    echo "$(date): Stopping tailscaled..." >> $log
    killall tailscaled >> $log 2>&1
    ;;
  *)
    echo "Usage: $0 {start|stop}" >&2
    exit 1
    ;;
esac
```

## Orthogonal issue with non-persistent MAC address

During the process of setting up my JetKVM, I noticed that I was getting a new IP every time the device restarted. The first thing I tried was to give in a static IP through my UniFi console, but was surprised when after a reboot I got yet another IP. This led to me finding this [GitHub issue](https://github.com/jetkvm/kvm/issues/375)that has a ton of activity on it. I suspect this will be fixed soon, but in the meantime, [this comment](https://github.com/jetkvm/kvm/issues/375#issuecomment-2832773429) had a solution that resolves the issue.
