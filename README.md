# Vanilla OpenWrt LuCI on TP-Link Archer AX10

> ⚠️ **Superseded.** This early proof-of-concept has grown into a complete, packaged system —
> a real `opkg` package manager, a modern **LuCI** web UI, a Broadcom wifi backend, and tiered
> **TP-Link debloat** — all built from source and installed with one command.
>
> **Just want it working? → [archer-boot.pages.dev](https://archer-boot.pages.dev)**
> · Source & docs: **[github.com/lee-soft/archer-ax10](https://github.com/lee-soft/archer-ax10)**
>
> This repo is kept for historical reference. New work happens in the project above.

Run vanilla OpenWrt LuCI 0.11.1 alongside the stock TP-Link web interface on a rooted Archer AX10.

## Background

The Archer AX10 runs a heavily modified version of LuCI with TP-Link's own encryption layer, custom HTTP handling, and modified Lua modules throughout. This project deploys clean upstream OpenWrt LuCI on top of the existing firmware without replacing or permanently modifying anything — everything runs from `/tmp` and the stock TP-Link interface on port 80 remains fully intact.

## How it works

- All filesystems on this router are ramfs/tmpfs and reset on every reboot
- A vanilla `uhttpd` binary serves LuCI from `/tmp` on port 8080
- A vanilla `dropbear` binary provides SSH access on port 2222
- Clean upstream OpenWrt 0.11.1 Lua modules are deployed over TP-Link's modified stack at runtime
- A single bootstrap command redeploys everything after each reboot

## Requirements

- Rooted Archer AX10
- Telnet access to the router
- Follow the rooting guide at [Waujito/TPLlAX1500GPL](https://github.com/Waujito/TPLlAX1500GPL)

## Usage

After each reboot, connect via telnet and run:

```sh
curl -4 -L -k -o /tmp/setup.sh https://raw.githubusercontent.com/lee-soft/LuCI-on-TP-Link-Archer-AX1500/main/setup.sh && chmod +x /tmp/setup.sh && /tmp/setup.sh
```

Then open your browser at:

```
http://<router-ip>:8080/cgi-bin/luci
```

SSH is available on port 2222 after the script runs.

## What the script does
1. Downloads the repo zip from GitHub
2. Extracts and deploys vanilla OpenWrt Lua modules to `/usr/lib/lua/luci/`
3. Deploys patched Lua modules for TP-Link WiFi compatibility:
   - `sys.lua` — adds `wifi.up()` and `wifi.down()` calling `wifi reload wl0/wl1`
   - `controller/admin/network.lua` — patches `wifi_reconnect_shutdown()` to use TP-Link's `enable`/`lastenable` UCI flags and per-radio reload
   - `model/cbi/admin_network/wifi.lua` — adds `brcmwifi` hwtype, maps password field to `psk_key`, syncs `enable`/`lastenable` on save
4. Clears LuCI module cache
5. Configures the UCI luci config (mediaurlbase, themes)
6. Sets the root password to empty
7. Starts vanilla dropbear SSH on port 2222
8. Starts vanilla uhttpd on port 8080

## Why this is non-trivial

TP-Link's modified LuCI stack required replacing the following core modules with clean upstream versions:

- `dispatcher.lua` — TP-Link added JSON encryption/wrapping of all responses
- `http.lua` — injected `luci.service` encryption layer
- `http/protocol.lua` — modified for TP-Link's data encryption scheme
- `sgi/cgi.lua` — modified CGI gateway
- `template.lua` — used TP-Link's custom `parser.so` C module
- `util.lua` — injected `luci.service`, `luarsa`, `luaaes` crypto dependencies
- `sauth.lua` — referenced `luci.tools.debug` which broke `libpath()` resolution

The `libpath()` function in vanilla LuCI uses `debug.getinfo()` to find its own location on disk. TP-Link's modified `sauth.lua` was loading `luci.tools.debug` instead of `luci.debug`, causing `libpath()` to return `/usr/lib/lua/luci/tools` instead of `/usr/lib/lua/luci`, which broke all CBI model and template resolution.

## WiFi integration patches

Getting WiFi toggle and configuration working from vanilla LuCI required some light  reverse engineering of TP-Link's proprietary WiFi management stack.

### Architecture
TP-Link completely bypasses OpenWrt's standard WiFi framework:
- `/lib/wifi/brcmwifi.sh` — stub file, all hooks (`enable_brcmwifi`, `disable_brcmwifi` etc.) are empty no-ops
- `/lib/wifi/tplink_brcm.sh` — ~5500 line real implementation (compiled LuaJIT bytecode for the web UI parts)
- The actual WiFi management chain is: UCI → `wifi_nvram_config()` → NVRAM → `hapdsupport` → `hostapd` → driver

### UCI field differences
TP-Link uses different UCI field names to vanilla OpenWrt:

| Vanilla OpenWrt | TP-Link AX10 |
|---|---|
| `key` | `psk_key` |
| `disabled=1/0` | `enable=on/off` + `lastenable=on/off` |
| `type=mac80211` | `type=brcmwifi` |
| `wifi up/down` | `wifi reload wl0` / `wifi reload wl1` |

### How WiFi enable/disable works
TP-Link does not use OpenWrt's `disabled` flag to toggle WiFi. Instead it sets:
- Enable: `uci set wireless.wl03.enable=on` + `lastenable=off`
- Disable: `uci set wireless.wl03.enable=off` + `lastenable=on`

Followed by `/sbin/wifi reload wl0` (per-radio, not a full reload). 

### Password/security chain
What I recall observing:
1. Setting `psk_key` in UCI then running `/sbin/wifi reload wl0` results in `nvram get wl0.1_wpa_psk` returning the new value
2. `/tmp/wl0.1_hapd.conf` is regenerated with the correct `wpa_passphrase`
3. `hostapd` is launched with `-B /tmp/wl0.1_hapd.conf`
4. WPA2 authentication works with the new password

The internal mechanics of how `wifi reload wl0` moves values from UCI to NVRAM to hostapd config were not fully traced.

### Files patched
| File | Change |
|---|---|
| `luci/controller/admin/network.lua` | Patched `wifi_reconnect_shutdown()` to set `enable`/`lastenable` and call per-radio reload |
| `luci/model/cbi/admin_network/wifi.lua` | Added `brcmwifi` hwtype support, changed password field from `key` to `psk_key`, added `enable`/`lastenable` sync in `on_commit` |

### Known limitations
- 2.4GHz radio (wl1) occasionally drops after ~10 seconds on first bring-up — this is a pre-existing driver/acsd timing issue unrelated to LuCI, and resolves itself on the next reload
- WiFi takes ~30 seconds to come up after enabling — this is normal ACS channel selection time
- Changes do not survive reboot — run the bootstrap command again after each reboot

### Building the binaries
Both binaries are cross-compiled using the GPL toolchain inside the waujito/tplax1500gpl:1.4 Docker environment.

dropbear
Download dropbear 2019.78 and compile with --host=arm-buildroot-linux-gnueabi, --disable-zlib, --disable-wtmp, --disable-lastlog.
Stock dropbear is modified with a MAC-based lockout that triggers even before authentication — the vanilla binary bypasses this entirely.

uhttpd
Source is already in the GPL cache: ~/router/Iplatform/openwrt/dl/uhttpd-2012-10-30-*.tar.gz
Compile with -DUBUS_SUPPORT=OFF -DTLS_SUPPORT=OFF -DLUA_SUPPORT=OFF. 

## Files
| File | Description |
|------|-------------|
| `setup.sh` | Bootstrap script — run this after every reboot |
| `uhttpd_vanilla` | Vanilla OpenWrt uhttpd binary |
| `dropbear_vanilla` | Vanilla OpenWrt dropbear binary |
| `www-vanilla/` | Vanilla OpenWrt LuCI web files |
| `luci-lua/` | Patched OpenWrt 0.11.1 Lua modules |

## Ports

| Port | Service |
|------|---------|
| 80 | Stock TP-Link web interface (unchanged) |
| 8080 | Vanilla OpenWrt LuCI |
| 2222 | Vanilla Dropbear SSH |

## Credits

- Rooting guide: [Waujito/TPLlAX1500GPL](https://github.com/Waujito/TPLlAX1500GPL)
- OpenWrt LuCI 0.11.1: [openwrt/luci](https://github.com/openwrt/luci)
- OpenWrt Attitude Adjustment 12.09 packages: [downloads.openwrt.org](http://downloads.openwrt.org/attitude_adjustment/12.09/)
