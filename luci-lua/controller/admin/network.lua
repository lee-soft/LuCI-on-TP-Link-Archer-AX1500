--[[
LuCI - Lua Configuration Interface

Copyright 2008 Steven Barth <steven@midlink.org>
Copyright 2011 Jo-Philipp Wich <xm@subsignal.org>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

	http://www.apache.org/licenses/LICENSE-2.0

brcmwifi changes vs upstream LuCI 0.11:
  - wifi_reconnect_shutdown: uses per-radio reload + per-VIF bss up/down
    instead of a full wifi down/up cycle.  ifname is read from UCI rather
    than hard-coded to <radio>.1 so guest/IoT VIFs on wl1 etc. work.
  - enable/disable flag is "enable=on/off" (TP-Link) not "disabled=1/0".
]]--

module("luci.controller.admin.network", package.seeall)

function index()
	local uci = require("luci.model.uci").cursor()
	local page

	page = node("admin", "network")
	page.target = firstchild()
	page.title  = _("Network")
	page.order  = 50
	page.index  = true

		local has_switch = false

		uci:foreach("network", "switch",
			function(s)
				has_switch = true
				return false
			end)

		if has_switch then
			page  = node("admin", "network", "vlan")
			page.target = cbi("admin_network/vlan")
			page.title  = _("Switch")
			page.order  = 20

			page = entry({"admin", "network", "switch_status"}, call("switch_status"), nil)
			page.leaf = true
		end


		local has_wifi = false

		uci:foreach("wireless", "wifi-device",
			function(s)
				has_wifi = true
				return false
			end)

		if has_wifi then
			page = entry({"admin", "network", "wireless_join"}, call("wifi_join"), nil)
			page.leaf = true

			page = entry({"admin", "network", "wireless_add"}, call("wifi_add"), nil)
			page.leaf = true

			page = entry({"admin", "network", "wireless_delete"}, call("wifi_delete"), nil)
			page.leaf = true

			page = entry({"admin", "network", "wireless_status"}, call("wifi_status"), nil)
			page.leaf = true

			page = entry({"admin", "network", "wireless_reconnect"}, call("wifi_reconnect"), nil)
			page.leaf = true

			page = entry({"admin", "network", "wireless_shutdown"}, call("wifi_shutdown"), nil)
			page.leaf = true

			page = entry({"admin", "network", "wireless"}, arcombine(template("admin_network/wifi_overview"), cbi("admin_network/wifi")), _("Wifi"), 15)
			page.leaf = true
			page.subindex = true

			if page.inreq then
				local wdev
				local net = require "luci.model.network".init(uci)
				for _, wdev in ipairs(net:get_wifidevs()) do
					local wnet
					for _, wnet in ipairs(wdev:get_wifinets()) do
						entry(
							{"admin", "network", "wireless", wnet:id()},
							alias("admin", "network", "wireless"),
							wdev:name() .. ": " .. wnet:shortname()
						)
					end
				end
			end
		end


		page = entry({"admin", "network", "iface_add"}, cbi("admin_network/iface_add"), nil)
		page.leaf = true

		page = entry({"admin", "network", "iface_delete"}, call("iface_delete"), nil)
		page.leaf = true

		page = entry({"admin", "network", "iface_status"}, call("iface_status"), nil)
		page.leaf = true

		page = entry({"admin", "network", "iface_reconnect"}, call("iface_reconnect"), nil)
		page.leaf = true

		page = entry({"admin", "network", "iface_shutdown"}, call("iface_shutdown"), nil)
		page.leaf = true

		page = entry({"admin", "network", "network"}, arcombine(cbi("admin_network/network"), cbi("admin_network/ifaces")), _("Interfaces"), 10)
		page.leaf   = true
		page.subindex = true

		if page.inreq then
			uci:foreach("network", "interface",
				function (section)
					local ifc = section[".name"]
					if ifc ~= "loopback" then
						entry({"admin", "network", "network", ifc},
						true, ifc:upper())
					end
				end)
		end


		if nixio.fs.access("/etc/config/dhcp") then
			page = node("admin", "network", "dhcp")
			page.target = cbi("admin_network/dhcp")
			page.title  = _("DHCP and DNS")
			page.order  = 30

			page = entry({"admin", "network", "dhcplease_status"}, call("lease_status"), nil)
			page.leaf = true

			page = node("admin", "network", "hosts")
			page.target = cbi("admin_network/hosts")
			page.title  = _("Hostnames")
			page.order  = 40
		end

		page  = node("admin", "network", "routes")
		page.target = cbi("admin_network/routes")
		page.title  = _("Static Routes")
		page.order  = 50

		page = node("admin", "network", "diagnostics")
		page.target = template("admin_network/diagnostics")
		page.title  = _("Diagnostics")
		page.order  = 60

		page = entry({"admin", "network", "diag_ping"}, call("diag_ping"), nil)
		page.leaf = true

		page = entry({"admin", "network", "diag_nslookup"}, call("diag_nslookup"), nil)
		page.leaf = true

		page = entry({"admin", "network", "diag_traceroute"}, call("diag_traceroute"), nil)
		page.leaf = true

		page = entry({"admin", "network", "diag_ping6"}, call("diag_ping6"), nil)
		page.leaf = true

		page = entry({"admin", "network", "diag_traceroute6"}, call("diag_traceroute6"), nil)
		page.leaf = true
end

function wifi_join()
	local function param(x)
		return luci.http.formvalue(x)
	end

	local function ptable(x)
		x = param(x)
		return x and (type(x) ~= "table" and { x } or x) or {}
	end

	local dev  = param("device")
	local ssid = param("join")

	if dev and ssid then
		local cancel  = (param("cancel") or param("cbi.cancel")) and true or false

		if cancel then
			luci.http.redirect(luci.dispatcher.build_url("admin/network/wireless_join?device=" .. dev))
		else
			local cbi = require "luci.cbi"
			local tpl = require "luci.template"
			local map = luci.cbi.load("admin_network/wifi_add")[1]

			if map:parse() ~= cbi.FORM_DONE then
				tpl.render("header")
				map:render()
				tpl.render("footer")
			end
		end
	else
		luci.template.render("admin_network/wifi_join")
	end
end

function wifi_add()
	local dev = luci.http.formvalue("device")
	local ntm = require "luci.model.network".init()

	dev = dev and ntm:get_wifidev(dev)

	if dev then
		local net = dev:add_wifinet({
			mode       = "ap",
			ssid       = "OpenWrt",
			encryption = "none"
		})

		ntm:save("wireless")
		luci.http.redirect(net:adminlink())
	end
end

function wifi_delete(network)
	local ntm = require "luci.model.network".init()
	local wnet = ntm:get_wifinet(network)
	if wnet then
		local dev = wnet:get_device()
		local nets = wnet:get_networks()
		if dev then
			luci.sys.call("env -i /sbin/wifi down %q >/dev/null" % dev:name())
			ntm:del_wifinet(network)
			ntm:commit("wireless")
			local _, net
			for _, net in ipairs(nets) do
				if net:is_empty() then
					ntm:del_network(net:name())
					ntm:commit("network")
				end
			end
			luci.sys.call("env -i /sbin/wifi up %q >/dev/null" % dev:name())
		end
	end

	luci.http.redirect(luci.dispatcher.build_url("admin/network/wireless"))
end

function iface_status(ifaces)
	local netm = require "luci.model.network".init()
	local rv   = { }

	local iface
	for iface in ifaces:gmatch("[%w%.%-_]+") do
		local net = netm:get_network(iface)
		local device = net and net:get_interface()
		if device then
			local data = {
				id         = iface,
				proto      = net:proto(),
				uptime     = net:uptime(),
				gwaddr     = net:gwaddr(),
				dnsaddrs   = net:dnsaddrs(),
				name       = device:shortname(),
				type       = device:type(),
				ifname     = device:name(),
				macaddr    = device:mac(),
				is_up      = device:is_up(),
				rx_bytes   = device:rx_bytes(),
				tx_bytes   = device:tx_bytes(),
				rx_packets = device:rx_packets(),
				tx_packets = device:tx_packets(),

				ipaddrs    = { },
				ip6addrs   = { },
				subdevices = { }
			}

			local _, a
			for _, a in ipairs(device:ipaddrs()) do
				data.ipaddrs[#data.ipaddrs+1] = {
					addr      = a:host():string(),
					netmask   = a:mask():string(),
					prefix    = a:prefix()
				}
			end
			for _, a in ipairs(device:ip6addrs()) do
				if not a:is6linklocal() then
					data.ip6addrs[#data.ip6addrs+1] = {
						addr      = a:host():string(),
						netmask   = a:mask():string(),
						prefix    = a:prefix()
					}
				end
			end

			for _, device in ipairs(net:get_interfaces() or {}) do
				data.subdevices[#data.subdevices+1] = {
					name       = device:shortname(),
					type       = device:type(),
					ifname     = device:name(),
					macaddr    = device:mac(),
					is_up      = device:is_up(),
					rx_bytes   = device:rx_bytes(),
					tx_bytes   = device:tx_bytes(),
					rx_packets = device:rx_packets(),
					tx_packets = device:tx_packets(),
				}
			end

			rv[#rv+1] = data
		else
			rv[#rv+1] = {
				id   = iface,
				name = iface,
				type = "ethernet"
			}
		end
	end

	if #rv > 0 then
		luci.http.prepare_content("application/json")
		luci.http.write_json(rv)
		return
	end

	luci.http.status(404, "No such device")
end

function iface_reconnect(iface)
	local netmd = require "luci.model.network".init()
	local net = netmd:get_network(iface)
	if net then
		luci.sys.call("env -i /sbin/ifup %q >/dev/null 2>/dev/null" % iface)
		luci.http.status(200, "Reconnected")
		return
	end

	luci.http.status(404, "No such interface")
end

function iface_shutdown(iface)
	local netmd = require "luci.model.network".init()
	local net = netmd:get_network(iface)
	if net then
		luci.sys.call("env -i /sbin/ifdown %q >/dev/null 2>/dev/null" % iface)
		luci.http.status(200, "Shutdown")
		return
	end

	luci.http.status(404, "No such interface")
end

function iface_delete(iface)
	local netmd = require "luci.model.network".init()
	local net = netmd:del_network(iface)
	if net then
		luci.sys.call("env -i /sbin/ifdown %q >/dev/null 2>/dev/null" % iface)
		luci.http.redirect(luci.dispatcher.build_url("admin/network/network"))
		netmd:commit("network")
		netmd:commit("wireless")
		return
	end

	luci.http.status(404, "No such interface")
end

function wifi_status(devs)
	local s    = require "luci.tools.status"
	local uci  = require("luci.model.uci").cursor()
	local rv   = { }

	-- Pre-build a map of ifname -> UCI encryption description for brcmwifi.
	-- iwinfo misreads the split psk_version/psk_cipher fields, so we always
	-- override with the UCI-derived string for any interface that uses them.
	local enc_override = {}
	uci:foreach("wireless", "wifi-iface", function(section)
		local ifname = section.ifname
		if not ifname then return end
		local enc = section.encryption or "none"
		local ver = section.psk_version or ""
		local label
		if     enc == "psk_sae" and ver == "sae_only"       then label = "WPA3-Personal"
		elseif enc == "psk_sae" and ver == "sae_transition" then label = "WPA2/WPA3-Personal"
		elseif enc == "psk"     and ver == "rsn"            then label = "WPA2-Personal"
		elseif enc == "psk"     and ver == "wpa"            then label = "WPA-Personal"
		elseif enc == "psk"     and ver == "auto"           then label = "WPA/WPA2-Personal"
		elseif enc == "owe"                                 then label = "Enhanced Open (OWE)"
		elseif enc == "wep"                                 then label = "WEP"
		elseif enc == "wpa"     and ver == "rsn"            then label = "WPA2-Enterprise"
		elseif enc == "wpa"                                 then label = "WPA-Enterprise"
		elseif enc == "none"                                then label = "None"
		end
		if label then
			enc_override[ifname] = label
		end
	end)

	local dev
	for dev in devs:gmatch("[%w%.%-]+") do
		local iw = s.wifi_network(dev)
		if enc_override[iw.ifname] then
			iw.encryption = enc_override[iw.ifname]
		end
		rv[#rv+1] = iw
	end

	if #rv > 0 then
		luci.http.prepare_content("application/json")
		luci.http.write_json(rv)
		return
	end

	luci.http.status(404, "No such device")
end
-- ------------------------------------------------------------
-- wifi_reconnect_shutdown (internal)
--
-- brcmwifi reload strategy:
--   1. Set enable=on/off in UCI and commit.
--   2. /sbin/wifi reload <radiodev>  -- per-radio, not full tear-down.
--   3. wl -i <ifname> bss up/down   -- bring just the VIF up or down.
--
-- The ifname is read from the UCI section (the "ifname" field that
-- TP-Link's wifi scripts write, e.g. "wl0.1", "wl1.1", "wl0.2").
-- If it is absent we fall back to <radiodev>.1 for primary VIFs,
-- but this is a best-effort fallback only.
--
-- We deliberately do NOT call "wifi down / wifi up" here because
-- that tears down every radio and every VIF simultaneously, which
-- causes a noticeable connectivity drop for all associated clients.
-- ------------------------------------------------------------
local function wifi_reconnect_shutdown(shutdown, wnet)
	local uci   = require("luci.model.uci").cursor()
	local netmd = require "luci.model.network".init()
	local net   = netmd:get_wifinet(wnet)
	local dev   = net and net:get_device()

	if dev and net then
		local sid    = net.sid
		local devsid = dev:name()

		-- Update the TP-Link enable/lastenable flags
		if shutdown then
			luci.sys.call("uci set wireless." .. sid .. ".enable=off")
			luci.sys.call("uci set wireless." .. sid .. ".lastenable=on")
		else
			luci.sys.call("uci set wireless." .. sid .. ".enable=on")
			luci.sys.call("uci set wireless." .. sid .. ".lastenable=off")
		end
		luci.sys.call("uci commit wireless")

		-- Reload the radio so nvram/hapd config is regenerated
		luci.sys.call("/sbin/wifi reload " .. devsid .. " >/dev/null 2>/dev/null")

		-- Resolve the actual VIF interface name from UCI.
		-- TP-Link stores the OS interface name in the ifname field of the
		-- wifi-iface section (e.g. "wl0.1").  Fall back to <radio>.1 only
		-- if that field is absent (e.g. after a manual UCI edit).
		local ifname = uci:get("wireless", sid, "ifname")
		if not ifname or ifname == "" then
			-- Derive VIF number from section index as a best effort.
			-- This counts all wifi-iface sections on the same device
			-- to find our position, giving wl0.1, wl0.2, etc.
			local vif_index = 1
			uci:foreach("wireless", "wifi-iface", function(s)
				if s[".name"] == sid then
					return false  -- stop iterating
				end
				if s.device == devsid then
					vif_index = vif_index + 1
				end
			end)
			ifname = devsid .. "." .. vif_index
		end

		if shutdown then
			luci.sys.fork_exec("/usr/sbin/wl -i " .. ifname .. " bss down")
		else
			luci.sys.fork_exec("/usr/sbin/wl -i " .. ifname .. " bss up")
		end

		luci.http.status(200, shutdown and "Shutdown" or "Reconnected")
		return
	end

	luci.http.status(404, "No such radio")
end

function wifi_reconnect(wnet)
	wifi_reconnect_shutdown(false, wnet)
end

function wifi_shutdown(wnet)
	wifi_reconnect_shutdown(true, wnet)
end

function lease_status()
	local s = require "luci.tools.status"

	luci.http.prepare_content("application/json")
	luci.http.write('[')
	luci.http.write_json(s.dhcp_leases())
	luci.http.write(',')
	luci.http.write_json(s.dhcp6_leases())
	luci.http.write(']')
end

function switch_status(switches)
	local s = require "luci.tools.status"

	luci.http.prepare_content("application/json")
	luci.http.write_json(s.switch_status(switches))
end

function diag_command(cmd, addr)
	if addr and addr:match("^[a-zA-Z0-9%-%.:_]+$") then
		luci.http.prepare_content("text/plain")

		local util = io.popen(cmd % addr)
		if util then
			while true do
				local ln = util:read("*l")
				if not ln then break end
				luci.http.write(ln)
				luci.http.write("\n")
			end

			util:close()
		end

		return
	end

	luci.http.status(500, "Bad address")
end

function diag_ping(addr)
	diag_command("ping -c 5 -W 1 %q 2>&1", addr)
end

function diag_traceroute(addr)
	diag_command("traceroute -q 1 -w 1 -n %q 2>&1", addr)
end

function diag_nslookup(addr)
	diag_command("nslookup %q 2>&1", addr)
end

function diag_ping6(addr)
	diag_command("ping6 -c 5 %q 2>&1", addr)
end

function diag_traceroute6(addr)
	diag_command("traceroute6 -q 1 -w 2 -n %q 2>&1", addr)
end