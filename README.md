# android-wifi-ipv6-keep

[中文说明 / Chinese documentation → README_CN.md](README_CN.md)

Adaptive IPv6 **default-route fallback** guard for **rooted Android**.

Keeps Wi-Fi IPv6 usable when the RA (Router Advertisement) default route
disappears or expires — a common symptom on some routers where Wi-Fi stays
connected and IPv6 addresses remain, but IPv6 traffic silently breaks after
a while.

> It does **not** reconnect Wi-Fi. It does **not** touch IPv4. It only
> maintains a low-priority backup IPv6 default route.

## What it fixes

- Wi-Fi connected, IPv6 address present, but IPv6 stops working after some
  time (RA default route lost / not refreshed).
- Router sends RA with short lifetimes, or stops refreshing them.

## What it does NOT fix

- Wi-Fi actually disconnecting (this script never reconnects Wi-Fi).
- Router's upstream / broadband IPv6 being down.
- DNS problems.
- IPv4 problems (IPv6 only).

## Requirements

- Rooted Android (Magisk / KernelSU / APatch)
- Wireless interface named `wlan0` (edit `IFACE=` if yours differs)
- The network must actually provide IPv6 (on an IPv4-only Wi-Fi it stays idle
  by design and adds nothing)

## Install

### One-click (recommended)

```sh
su -c 'sh /sdcard/Download/deploy-wifi-keep.sh'
```

The deploy script is self-contained: it backs up any existing script, writes
`wifi-keep.sh`, syntax-checks it (rolls back on failure), stops the old
process and starts the new one.

### Manual

```sh
su
cp wifi-keep.sh /data/adb/service.d/wifi-keep.sh
chmod 755 /data/adb/service.d/wifi-keep.sh
chown 0:0 /data/adb/service.d/wifi-keep.sh
sh -n /data/adb/service.d/wifi-keep.sh && echo SYNTAX_OK
nohup /system/bin/sh /data/adb/service.d/wifi-keep.sh >> /data/adb/wifi-keep/launcher.log 2>&1 </dev/null &
```

It auto-starts on boot via `service.d`.

## Verify

```sh
ip -6 route show table wlan0
```

You should see two default routes:

```
default via fe80:... dev wlan0 proto ra  metric 1024 ...   <- normal (from RA)
default via fe80:... dev wlan0 proto 99  metric 4096 ...   <- backup (this script)
```

`proto 99` / `metric 4096` is this script's signature. It only ever removes
routes carrying that signature, never the normal RA route.

## How it works

1. Learns the gateway from the existing RA default route (plus its MTU).
2. Verifies the gateway is alive (`ping6` + neighbour MAC check).
3. Installs a backup default route: `proto 99 metric 4096`, no expiry.
4. Re-verifies gateway health every 300s (60s after a failure, warns after 3
   consecutive failures — but **never** deletes the backup for a ping failure).
5. Pauses entirely when Android's default network is cellular, removing the
   backup route; resumes and re-verifies when Wi-Fi becomes default again.
6. Switches gateways atomically (`ip route replace`) after verifying the new
   one, so there is no gap.

## Safety notes

- Only removes routes matching `proto 99` + `metric 4096` (its own).
- Never reconnects Wi-Fi or changes your network selection.
- Sets `accept_ra=2`, `accept_ra_min_lft=1` and disables Wi-Fi power save
  (`KEEP_POWER_SAVE_OFF=1`); these are **not** restored on exit.
- No wakelock; idle polling is cheap (~0.12% duty cycle).

## Log

```sh
tail -f /data/adb/wifi-keep/wifi-keep.log
```

## License

MIT
