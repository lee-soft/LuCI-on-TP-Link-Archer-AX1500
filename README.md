# Vanilla OpenWrt LuCI on TP-Link Archer AX10

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
curl -4 -L -k -o /tmp/setup.sh https://github.com/lee-soft/LuCI-on-TP-Link-Archer-AX1500/blob/main/setup.sh && chmod +x /tmp/setup.sh && /tmp/setup.sh
```

Then open your browser at:

```
http://<router-ip>:8080/cgi-bin/luci
```

SSH is available on port 2222 after the script runs.

## What the script does

1. Downloads `luci-deploy.zip` from lee-soft github
2. Extracts and deploys vanilla OpenWrt Lua modules to `/usr/lib/lua/luci/`
3. Configures the UCI luci config (mediaurlbase, themes)
4. Sets the root password to empty
5. Starts vanilla dropbear SSH on port 2222
6. Starts vanilla uhttpd on port 8080

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

## Files

| File | Description |
|------|-------------|
| `setup.sh` | Bootstrap script — run this after every reboot |
| `luci-deploy.zip` | Full deployment package (Lua modules, www files, binaries) |

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
