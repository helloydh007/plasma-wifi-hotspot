# KDE Hotspot Control

A Plasma 6 system-tray applet + privileged backend to switch a Wi-Fi hotspot on/off with one click, in two distinctly different modes.

> [中文文档（主文档）](README.md) — this English page is a summary; the Chinese README is the primary, most up-to-date documentation.

Developed and tested on **Debian 13 + KDE Plasma 6.3 (Intel AX201 / iwlwifi)**.

## Motivation

Windows' Mobile Hotspot can run **while the same Wi-Fi adapter stays connected to a network** —
one radio, online and sharing at the same time. The Linux desktop has no such experience out of the
box (NetworkManager's hotspot kicks the client off). This project exists to bring that Windows
capability to Linux: **run a hotspot without giving up the Wi-Fi connection or plugging in a cable**.
It does so with the concurrent mode (hostapd on a virtual `ap0` interface), while keeping the more
portable normal mode (NetworkManager native hotspot, Wi-Fi disconnected) as a fallback. See the
hardware constraints below for why concurrent mode is limited to 2.4 GHz on one channel here.

![Plugin UI](docs/screenshot.png)

## Features

- **Two hotspot modes** (see below): *concurrent* keeps your Wi-Fi client connected; *normal* turns the whole card into an AP
- **Tray icon reflects state**: a hotspot icon while running; **the same icon with a red slash** (muted-icon style) when off/unavailable; hover shows status, band, channel and client count
- **Live status**: the icon follows external changes too (CLI toggles, the supervisor auto-pausing the hotspot when Wi-Fi roams) — polling every 5 s by default, adjustable 2–60 s
- Panel controls: on/off, mode radio buttons, **start-at-boot** toggle, **dependency self-check** with copy-paste fix commands
- **Change hotspot SSID/password** right in the panel; the running hotspot is restarted automatically so new values take effect; the **current password is viewable** (masked by default, eye button reveals it)
- **Password-free operation**: a polkit rule authorizes exactly one control script (see Security)
- **Bilingual UI follows the system language** (KDE-standard i18n: English source strings, `zh_CN` catalog compiled into the package; regenerate with `./build-translations.sh`. Backend result messages are Chinese-only for now)
- Also installable as a **desktop entry** (app menu / KRunner: "Wi-Fi Hotspot Control") opening the same UI in a standalone window

## The two modes

| | Concurrent mode | Normal mode |
|---|---|---|
| Wi-Fi client | **stays connected** (no speed impact) | **must disconnect** (that's what defines this mode) |
| How | hostapd on a virtual `ap0` interface + dnsmasq + iptables NAT | NetworkManager native hotspot (`ipv4.method shared`, auto DHCP/NAT) |
| Band | 2.4 GHz, **follows the Wi-Fi client's channel** | 2.4 GHz (ch6) |
| Uplink | the current Wi-Fi connection | the default-route device (e.g. ethernet); without uplink it's LAN-only |

## Hardware facts and limitations (measured)

On Intel AX201 + `iwlwifi`:

1. **5 GHz AP is impossible** — the firmware's regulatory domain is self-managed and marks all of 5 GHz as NO-IR; `iw reg set` cannot change it. Both modes are 2.4 GHz-only.
2. **STA and AP must share one channel** — the driver allows `{managed} <= 1, {AP} <= 1, #channels <= 1`. Concurrent mode only works while the Wi-Fi client is on 2.4 GHz; otherwise the applet shows "standby".
3. **NetworkManager's own hotspot kicks the client off** (it flips the whole NIC from managed to AP). That's why concurrent mode uses hostapd on a virtual interface instead.

This also explains why Windows can do "Wi-Fi + hotspot at once": its Mobile Hotspot uses Wi-Fi Direct (P2P-GO), which this chipset allows on a second channel; plain Linux AP mode has no such path.

## Requirements

- KDE Plasma 6 + Qt6 (**Plasma 5 will not work**), `kpackagetool6`, `org.kde.plasma.plasma5support` — all shipped with Plasma
- NetworkManager, polkit/pkexec, systemd
- Packages: `sudo apt install hostapd dnsmasq iw iptables`
- A NIC that supports AP mode (`iw list` → "Supported interface modes" contains `AP`); concurrent mode additionally needs the managed+AP combination on one channel

## Install

```bash
sudo apt install hostapd dnsmasq iw iptables   # only what's missing
git clone <this repo> && cd kde-hotspot-control
bash install.sh
```

`install.sh` does four things: deploys the backend via pkexec (one auth prompt), installs the plasmoid user-level, installs a desktop entry, and restarts plasmashell. Then:

1. Edit `/etc/kde-hotspot/config` (mode 600) and set your `SSID` / `PASS`. **The backend refuses to start the hotspot with missing credentials** — no default passwords.
2. Add the applet to the system tray: right-click the panel → Edit System Tray → Entries → enable "Wi-Fi 热点控制", or drag it onto the panel.

## Update

```bash
git pull
bash install.sh   # re-syncs backend, updates the plasmoid, restarts plasmashell
```

plasmashell caches QML in memory — an update without the restart keeps the old UI running. `install.sh` handles it.

## Usage / CLI

```bash
pkexec /usr/local/sbin/kde-hotspot-ctl status          # status JSON (includes current SSID/password)
pkexec /usr/local/sbin/kde-hotspot-ctl on|off          # toggle in the current mode
pkexec /usr/local/sbin/kde-hotspot-ctl mode concurrent|normal
pkexec /usr/local/sbin/kde-hotspot-ctl autostart on|off
pkexec /usr/local/sbin/kde-hotspot-ctl set-credentials <SSID> [<new password>]
```

Action commands print one JSON line (`{"ok":true,"message":"…"}`) on stdout — that's what the applet parses.

## Security

- The polkit rule authorizes **only `/usr/local/sbin/kde-hotspot-ctl`** (the action carries an `org.freedesktop.policykit.exec.path` annotation); it cannot run arbitrary commands. Delete `/etc/polkit-1/rules.d/49-kde-hotspot.rules` to restore password prompts.
- Package installation is deliberately **not** inside the password-free scope.
- The hotspot password lives in `/etc/kde-hotspot/config` (600, root-only). `status` exposes it to the authorized user session so the applet can display it; on a shared system, remove the `"pass"` field from `do_status` if that is unacceptable.

## Uninstall

See the Chinese README (卸载) for the full script; in short: stop/disable the three `kde-hotspot*` systemd units, remove the backend files (`/usr/local/sbin/kde-hotspot-ctl`, `/usr/local/sbin/kde-hotspot.sh`, the units, the polkit policy + rule, the NetworkManager `conf.d` file, `/etc/kde-hotspot`, `/var/lib/kde-hotspot`), clean up the `ap0` interface and the `kde-hotspot-normal` NM profile if present, then `kpackagetool6 -t Plasma/Applet -r org.kde.hotspot` and remove `~/.local/share/applications/org.kde.hotspot.desktop`.

## License

GPL-2.0-or-later (see `LICENSE`).
