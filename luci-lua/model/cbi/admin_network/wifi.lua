--[[
LuCI - Lua Configuration Interface

Copyright 2008 Steven Barth <steven@midlink.org>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

	http://www.apache.org/licenses/LICENSE-2.0

brcmwifi driver additions:
  - WPA3-Personal (SAE), WPA2/WPA3 transition, Enhanced Open (OWE)
  - Correct encryption cfgvalue/write round-trip via psk_version + psk_cipher
  - HT/VHT/HE channel width (htmode / vhtmode / hemode)
  - 802.11n/ac/ax hwmode entries
  - Per-VIF bss up/down in on_commit instead of full wifi down/up cycle
  - sae_password UCI field for WPA3
]]--

local wa = require "luci.tools.webadmin"
local nw = require "luci.model.network"
local ut = require "luci.util"
local nt = require "luci.sys".net
local fs = require "nixio.fs"

arg[1] = arg[1] or ""

m = Map("wireless", "",
	translate("The <em>Device Configuration</em> section covers physical settings of the radio " ..
		"hardware such as channel, transmit power or antenna selection which is shared among all " ..
		"defined wireless networks (if the radio hardware is multi-SSID capable). Per network settings " ..
		"like encryption or operation mode are grouped in the <em>Interface Configuration</em>."))

m:chain("network")
m:chain("firewall")

local ifsection

function m.on_commit(map)
	local wnet = nw:get_wifinet(arg[1])
	if ifsection and wnet then
		ifsection.section = wnet.sid
		m.title = luci.util.pcdata(wnet:get_i18n())
	end
	if wnet then
		local sid    = wnet.sid
		local dev    = wnet:get_device()
		local devsid = dev and dev:name()
		if devsid then
			-- Ensure device disabled=0 so wifi_security_config runs
			m.uci:set("wireless", devsid, "disabled", "0")
			m.uci:commit("wireless")

			-- Reload the radio to pick up nvram/UCI changes
			os.execute("/sbin/wifi reload " .. devsid .. " >/dev/null 2>/dev/null")

			-- Bring the specific VIF interface up or down based on its
			-- enable flag.  The ifname for the VIF is the UCI section
			-- name itself (e.g. wl0.1, wl1.1).
			local ifname = m.uci:get("wireless", sid, "ifname") or (devsid .. ".1")
			local enable = m.uci:get("wireless", sid, "enable")
			if enable == "on" then
				os.execute("/usr/sbin/wl -i " .. ifname .. " bss up >/dev/null 2>/dev/null")
			else
				os.execute("/usr/sbin/wl -i " .. ifname .. " bss down >/dev/null 2>/dev/null")
			end
		end
	end
end

nw.init(m.uci)

local wnet = nw:get_wifinet(arg[1])
local wdev = wnet and wnet:get_device()

-- redirect to overview page if network does not exist anymore (e.g. after a revert)
if not wnet or not wdev then
	luci.http.redirect(luci.dispatcher.build_url("admin/network/wireless"))
	return
end

-- wireless toggle was requested, commit and reload page.
-- Use per-device reload, not full wifi down/up.
function m.parse(map)
	if m:formvalue("cbid.wireless.%s.__toggle" % wdev:name()) then
		if wdev:get("disabled") == "1" or wnet:get("disabled") == "1" then
			wnet:set("disabled", nil)
		else
			wnet:set("disabled", "1")
		end
		wdev:set("disabled", nil)
		nw:commit("wireless")

		local devsid = wdev:name()
		os.execute("/sbin/wifi reload " .. devsid .. " >/dev/null 2>/dev/null")

		luci.http.redirect(luci.dispatcher.build_url("admin/network/wireless", arg[1]))
		return
	end
	Map.parse(map)
end

m.title = luci.util.pcdata(wnet:get_i18n())


local function txpower_list(iw)
	local list = iw.txpwrlist or { }
	local off  = tonumber(iw.txpower_offset) or 0
	local new  = { }
	local prev = -1
	local _, val
	for _, val in ipairs(list) do
		local dbm = val.dbm + off
		local mw  = math.floor(10 ^ (dbm / 10))
		if mw ~= prev then
			prev = mw
			new[#new+1] = {
				display_dbm = dbm,
				display_mw  = mw,
				driver_dbm  = val.dbm,
				driver_mw   = val.mw
			}
		end
	end
	return new
end

local function txpower_current(pwr, list)
	pwr = tonumber(pwr)
	if pwr ~= nil then
		local _, item
		for _, item in ipairs(list) do
			if item.driver_dbm >= pwr then
				return item.driver_dbm
			end
		end
	end
	return (list[#list] and list[#list].driver_dbm) or pwr or 0
end

local iw = luci.sys.wifi.getiwinfo(arg[1])
local hw_modes      = iw.hwmodelist or { }
local tx_power_list = txpower_list(iw)
local tx_power_cur  = txpower_current(wdev:get("txpower"), tx_power_list)

s = m:section(NamedSection, wdev:name(), "wifi-device", translate("Device Configuration"))
s.addremove = false

s:tab("general",  translate("General Setup"))
s:tab("macfilter", translate("MAC-Filter"))
s:tab("advanced", translate("Advanced Settings"))

st = s:taboption("general", DummyValue, "__status", translate("Status"))
st.template = "admin_network/wifi_status"
st.ifname   = arg[1]

en = s:taboption("general", Button, "__toggle")

if wdev:get("disabled") == "1" or wnet:get("disabled") == "1" then
	en.title      = translate("Wireless network is disabled")
	en.inputtitle = translate("Enable")
	en.inputstyle = "apply"
else
	en.title      = translate("Wireless network is enabled")
	en.inputtitle = translate("Disable")
	en.inputstyle = "reset"
end


local hwtype = wdev:get("type")
local htcaps = wdev:get("ht_capab") and true or false

local nsantenna = wdev:get("antenna")

local skip_sta_lock = (hwtype == "brcmwifi")

local has_sta = nil
if not skip_sta_lock then
    local _, net
    for _, net in ipairs(wdev:get_wifinets()) do
        if net:mode() == "sta" and net:id() ~= wnet:id() then
            has_sta = net
            break
        end
    end
end

if has_sta then
	ch = s:taboption("general", DummyValue, "choice", translate("Channel"))
	ch.value = translatef("Locked to channel %d used by %s",
		has_sta:channel(), has_sta:shortname())
else
	ch = s:taboption("general", Value, "channel", translate("Channel"))
	ch:value("auto", translate("auto"))
	for _, f in ipairs(iw and iw.freqlist or { }) do
		if not f.restricted then
			ch:value(f.channel, "%i (%.3f GHz)" %{ f.channel, f.mhz / 1000 })
		end
	end
end


------------------- MAC80211 Device ------------------

if hwtype == "mac80211" then
	if #tx_power_list > 1 then
		tp = s:taboption("general", ListValue,
			"txpower", translate("Transmit Power"), "dBm")
		tp.rmempty = true
		tp.default = tx_power_cur
		function tp.cfgvalue(...)
			return txpower_current(Value.cfgvalue(...), tx_power_list)
		end

		for _, p in ipairs(tx_power_list) do
			tp:value(p.driver_dbm, "%i dBm (%i mW)"
				%{ p.display_dbm, p.display_mw })
		end
	end

	mode = s:taboption("advanced", ListValue, "hwmode", translate("Mode"))
	mode:value("", translate("auto"))
	if hw_modes.b then mode:value("11b", "802.11b") end
	if hw_modes.g then mode:value("11g", "802.11g") end
	if hw_modes.a then mode:value("11a", "802.11a") end

	if htcaps then
		if hw_modes.g and hw_modes.n then mode:value("11ng", "802.11g+n") end
		if hw_modes.a and hw_modes.n then mode:value("11na", "802.11a+n") end

		htmode = s:taboption("advanced", ListValue, "htmode", translate("HT mode"))
		htmode:depends("hwmode", "11na")
		htmode:depends("hwmode", "11ng")
		htmode:value("HT20", "20MHz")
		htmode:value("HT40-", translate("40MHz 2nd channel below"))
		htmode:value("HT40+", translate("40MHz 2nd channel above"))

		noscan = s:taboption("advanced", Flag, "noscan", translate("Force 40MHz mode"),
			translate("Always use 40MHz channels even if the secondary channel overlaps. Using this option does not comply with IEEE 802.11n-2009!"))
		noscan:depends("htmode", "HT40+")
		noscan:depends("htmode", "HT40-")
		noscan.default = noscan.disabled
	end

	local cl = iw and iw.countrylist
	if cl and #cl > 0 then
		cc = s:taboption("advanced", ListValue, "country", translate("Country Code"), translate("Use ISO/IEC 3166 alpha2 country codes."))
		cc.default = tostring(iw and iw.country or "00")
		for _, c in ipairs(cl) do
			cc:value(c.alpha2, "%s - %s" %{ c.alpha2, c.name })
		end
	else
		s:taboption("advanced", Value, "country", translate("Country Code"), translate("Use ISO/IEC 3166 alpha2 country codes."))
	end

	s:taboption("advanced", Value, "distance", translate("Distance Optimization"),
		translate("Distance to farthest network member in meters."))

	local eal = iw and iw.extant
	if eal and #eal > 0 then
		ea = s:taboption("advanced", ListValue, "extant", translate("Antenna Configuration"))
		for _, eap in ipairs(eal) do
			ea:value(eap.id, "%s (%s)" %{ eap.name, eap.description })
			if eap.selected then
				ea.default = eap.id
			end
		end
	end

	s:taboption("advanced", Value, "frag", translate("Fragmentation Threshold"))
	s:taboption("advanced", Value, "rts", translate("RTS/CTS Threshold"))
end


------------------- Madwifi Device ------------------

if hwtype == "atheros" then
	tp = s:taboption("general",
		(#tx_power_list > 0) and ListValue or Value,
		"txpower", translate("Transmit Power"), "dBm")

	tp.rmempty = true
	tp.default = tx_power_cur

	function tp.cfgvalue(...)
		return txpower_current(Value.cfgvalue(...), tx_power_list)
	end

	for _, p in ipairs(tx_power_list) do
		tp:value(p.driver_dbm, "%i dBm (%i mW)"
			%{ p.display_dbm, p.display_mw })
	end

	mode = s:taboption("advanced", ListValue, "hwmode", translate("Mode"))
	mode:value("", translate("auto"))
	if hw_modes.b then mode:value("11b", "802.11b") end
	if hw_modes.g then mode:value("11g", "802.11g") end
	if hw_modes.a then mode:value("11a", "802.11a") end
	if hw_modes.g then mode:value("11bg", "802.11b+g") end
	if hw_modes.g then mode:value("11gst", "802.11g + Turbo") end
	if hw_modes.a then mode:value("11ast", "802.11a + Turbo") end
	mode:value("fh", translate("Frequency Hopping"))

	s:taboption("advanced", Flag, "diversity", translate("Diversity")).rmempty = false

	if not nsantenna then
		ant1 = s:taboption("advanced", ListValue, "txantenna", translate("Transmitter Antenna"))
		ant1.widget = "radio"
		ant1.orientation = "horizontal"
		ant1:depends("diversity", "")
		ant1:value("0", translate("auto"))
		ant1:value("1", translate("Antenna 1"))
		ant1:value("2", translate("Antenna 2"))

		ant2 = s:taboption("advanced", ListValue, "rxantenna", translate("Receiver Antenna"))
		ant2.widget = "radio"
		ant2.orientation = "horizontal"
		ant2:depends("diversity", "")
		ant2:value("0", translate("auto"))
		ant2:value("1", translate("Antenna 1"))
		ant2:value("2", translate("Antenna 2"))

	else
		local ant = s:taboption("advanced", ListValue, "antenna", translate("Transmitter Antenna"))
		ant:value("auto")
		ant:value("vertical")
		ant:value("horizontal")
		ant:value("external")
	end

	s:taboption("advanced", Value, "distance", translate("Distance Optimization"),
		translate("Distance to farthest network member in meters."))
	s:taboption("advanced", Value, "regdomain", translate("Regulatory Domain"))
	s:taboption("advanced", Value, "country", translate("Country Code"))
	s:taboption("advanced", Flag, "outdoor", translate("Outdoor Channels"))
end


------------------- Broadcom Device ------------------
--
-- brcmwifi UCI device fields used here:
--   type        = "brcmwifi"
--   hwmode      = "11bg" | "11b" | "11g" | "11ng" | "11na" | "11ac" | "11ax"
--   htmode      = "HT20" | "HT40+" | "HT40-" | "HT40" (auto-sideband)
--   vhtmode     = "VHT20" | "VHT40" | "VHT80" | "VHT80+80" | "VHT160"
--   hemode      = "HE20"  | "HE40"  | "HE80"  | "HE160"
--   txpower     = <dBm>
--   country     = <alpha2>
--   maxassoc    = <n>
--   frameburst  = "1" | "0"
--   txantenna   = "3" (auto) | "0" | "1"
--   rxantenna   = "3" (auto) | "0" | "1"

if hwtype == "brcmwifi" then
	tp = s:taboption("general",
		(#tx_power_list > 0) and ListValue or Value,
		"txpower", translate("Transmit Power"), "dBm")

	tp.rmempty = true
	tp.default = tx_power_cur

	function tp.cfgvalue(...)
		return txpower_current(Value.cfgvalue(...), tx_power_list)
	end

	for _, p in ipairs(tx_power_list) do
		tp:value(p.driver_dbm, "%i dBm (%i mW)"
			%{ p.display_dbm, p.display_mw })
	end

	-- 802.11 mode selection
	-- brcmwifi uses combined hwmode strings; the driver interprets them.
	mode = s:taboption("advanced", ListValue, "hwmode", translate("Mode"))
	mode:value("11bg",  "802.11b/g")
	mode:value("11b",   "802.11b")
	mode:value("11g",   "802.11g")
	mode:value("11gst", "802.11g Turbo")
	mode:value("11ng",  "802.11b/g/n")
	mode:value("11na",  "802.11a/n")
	mode:value("11ac",  "802.11a/n/ac")
	mode:value("11ax",  "802.11a/n/ac/ax (Wi-Fi 6)")

	-- HT channel width (802.11n)
	htmode = s:taboption("advanced", ListValue, "htmode", translate("HT Channel Width"))
	htmode:depends("hwmode", "11ng")
	htmode:depends("hwmode", "11na")
	htmode:depends("hwmode", "11ac")
	htmode:depends("hwmode", "11ax")
	htmode:value("HT20",   "20 MHz")
	htmode:value("HT40+",  translate("40 MHz (upper sideband)"))
	htmode:value("HT40-",  translate("40 MHz (lower sideband)"))
	htmode:value("HT40",   translate("40 MHz (auto sideband)"))

	-- VHT channel width (802.11ac)
	vhtmode = s:taboption("advanced", ListValue, "vhtmode", translate("VHT Channel Width"))
	vhtmode:depends("hwmode", "11ac")
	vhtmode:depends("hwmode", "11ax")
	vhtmode:value("VHT20",    "20 MHz")
	vhtmode:value("VHT40",    "40 MHz")
	vhtmode:value("VHT80",    "80 MHz")
	vhtmode:value("VHT80+80", "80+80 MHz")
	vhtmode:value("VHT160",   "160 MHz")

	-- HE channel width (802.11ax / Wi-Fi 6)
	hemode = s:taboption("advanced", ListValue, "hemode", translate("HE Channel Width (Wi-Fi 6)"))
	hemode:depends("hwmode", "11ax")
	hemode:value("HE20",  "20 MHz")
	hemode:value("HE40",  "40 MHz")
	hemode:value("HE80",  "80 MHz")
	hemode:value("HE160", "160 MHz")

	ant1 = s:taboption("advanced", ListValue, "txantenna", translate("Transmitter Antenna"))
	ant1.widget = "radio"
	ant1:value("3", translate("auto"))
	ant1:value("0", translate("Antenna 1"))
	ant1:value("1", translate("Antenna 2"))

	ant2 = s:taboption("advanced", ListValue, "rxantenna", translate("Receiver Antenna"))
	ant2.widget = "radio"
	ant2:value("3", translate("auto"))
	ant2:value("0", translate("Antenna 1"))
	ant2:value("1", translate("Antenna 2"))

	s:taboption("advanced", Flag, "frameburst", translate("Frame Bursting"))
	s:taboption("advanced", Value, "distance",  translate("Distance Optimization"))
	s:taboption("advanced", Value, "country",   translate("Country Code"))
	s:taboption("advanced", Value, "maxassoc",  translate("Connection Limit"))
end


--------------------- HostAP Device ---------------------

if hwtype == "prism2" then
	s:taboption("advanced", Value, "txpower", translate("Transmit Power"), "att units").rmempty = true
	s:taboption("advanced", Flag,  "diversity", translate("Diversity")).rmempty = false
	s:taboption("advanced", Value, "txantenna", translate("Transmitter Antenna"))
	s:taboption("advanced", Value, "rxantenna", translate("Receiver Antenna"))
end


----------------------- Interface -----------------------

s = m:section(NamedSection, wnet.sid, "wifi-iface", translate("Interface Configuration"))
ifsection = s
s.addremove = false
s.anonymous = true
s.defaults.device = wdev:name()

s:tab("general",    translate("General Setup"))
s:tab("encryption", translate("Wireless Security"))
s:tab("macfilter",  translate("MAC-Filter"))
s:tab("advanced",   translate("Advanced Settings"))

s:taboption("general", Value, "ssid", translate("<abbr title=\"Extended Service Set Identifier\">ESSID</abbr>"))

mode = s:taboption("general", ListValue, "mode", translate("Mode"))
mode.override_values = true
mode:value("ap",    translate("Access Point"))
mode:value("sta",   translate("Client"))
mode:value("adhoc", translate("Ad-Hoc"))

bssid = s:taboption("general", Value, "bssid", translate("<abbr title=\"Basic Service Set Identifier\">BSSID</abbr>"))

network = s:taboption("general", Value, "network", translate("Network"),
	translate("Choose the network(s) you want to attach to this wireless interface or " ..
		"fill out the <em>create</em> field to define a new network."))

network.rmempty = true
network.template = "cbi/network_netlist"
network.widget = "checkbox"
network.novirtual = true

function network.write(self, section, value)
	local i = nw:get_interface(section)
	if i then
		if value == '-' then
			value = m:formvalue(self:cbid(section) .. ".newnet")
			if value and #value > 0 then
				local n = nw:add_network(value, {proto="none"})
				if n then n:add_interface(i) end
			else
				local n = i:get_network()
				if n then n:del_interface(i) end
			end
		else
			local v
			for _, v in ipairs(i:get_networks()) do
				v:del_interface(i)
			end
			for v in ut.imatch(value) do
				local n = nw:get_network(v)
				if n then
					if not n:is_empty() then
						n:set("type", "bridge")
					end
					n:add_interface(i)
				end
			end
		end
	end
end


-------------------- MAC80211 Interface ----------------------

if hwtype == "mac80211" then
	if fs.access("/usr/sbin/iw") then
		mode:value("mesh", "802.11s")
	end

	mode:value("ahdemo",  translate("Pseudo Ad-Hoc (ahdemo)"))
	mode:value("monitor", translate("Monitor"))
	bssid:depends({mode="adhoc"})
	bssid:depends({mode="sta"})
	bssid:depends({mode="sta-wds"})

	mp = s:taboption("macfilter", ListValue, "macfilter", translate("MAC-Address Filter"))
	mp:depends({mode="ap"})
	mp:depends({mode="ap-wds"})
	mp:value("",      translate("disable"))
	mp:value("allow", translate("Allow listed only"))
	mp:value("deny",  translate("Allow all except listed"))

	ml = s:taboption("macfilter", DynamicList, "maclist", translate("MAC-List"))
	ml.datatype = "macaddr"
	ml:depends({macfilter="allow"})
	ml:depends({macfilter="deny"})
	nt.mac_hints(function(mac, name) ml:value(mac, "%s (%s)" %{ mac, name }) end)

	mode:value("ap-wds",  "%s (%s)" % {translate("Access Point"), translate("WDS")})
	mode:value("sta-wds", "%s (%s)" % {translate("Client"),       translate("WDS")})

	function mode.write(self, section, value)
		if value == "ap-wds" then
			ListValue.write(self, section, "ap")
			m.uci:set("wireless", section, "wds", 1)
		elseif value == "sta-wds" then
			ListValue.write(self, section, "sta")
			m.uci:set("wireless", section, "wds", 1)
		else
			ListValue.write(self, section, value)
			m.uci:delete("wireless", section, "wds")
		end
	end

	function mode.cfgvalue(self, section)
		local mode = ListValue.cfgvalue(self, section)
		local wds  = m.uci:get("wireless", section, "wds") == "1"
		if mode == "ap"  and wds then return "ap-wds"
		elseif mode == "sta" and wds then return "sta-wds"
		else return mode end
	end

	hidden = s:taboption("general", Flag, "hidden", translate("Hide <abbr title=\"Extended Service Set Identifier\">ESSID</abbr>"))
	hidden:depends({mode="ap"})
	hidden:depends({mode="ap-wds"})

	wmm = s:taboption("general", Flag, "wmm", translate("WMM Mode"))
	wmm:depends({mode="ap"})
	wmm:depends({mode="ap-wds"})
	wmm.default = wmm.enabled
end


-------------------- Madwifi Interface ----------------------

if hwtype == "atheros" then
	mode:value("ahdemo",  translate("Pseudo Ad-Hoc (ahdemo)"))
	mode:value("monitor", translate("Monitor"))
	mode:value("ap-wds",  "%s (%s)" % {translate("Access Point"), translate("WDS")})
	mode:value("sta-wds", "%s (%s)" % {translate("Client"),       translate("WDS")})
	mode:value("wds",     translate("Static WDS"))

	function mode.write(self, section, value)
		if value == "ap-wds" then
			ListValue.write(self, section, "ap")
			m.uci:set("wireless", section, "wds", 1)
		elseif value == "sta-wds" then
			ListValue.write(self, section, "sta")
			m.uci:set("wireless", section, "wds", 1)
		else
			ListValue.write(self, section, value)
			m.uci:delete("wireless", section, "wds")
		end
	end

	function mode.cfgvalue(self, section)
		local mode = ListValue.cfgvalue(self, section)
		local wds  = m.uci:get("wireless", section, "wds") == "1"
		if mode == "ap"  and wds then return "ap-wds"
		elseif mode == "sta" and wds then return "sta-wds"
		else return mode end
	end

	bssid:depends({mode="adhoc"})
	bssid:depends({mode="ahdemo"})
	bssid:depends({mode="wds"})

	wdssep = s:taboption("advanced", Flag, "wdssep", translate("Separate WDS"))
	wdssep:depends({mode="ap-wds"})

	s:taboption("advanced", Flag, "doth", "802.11h")
	hidden = s:taboption("general", Flag, "hidden", translate("Hide <abbr title=\"Extended Service Set Identifier\">ESSID</abbr>"))
	hidden:depends({mode="ap"})
	hidden:depends({mode="adhoc"})
	hidden:depends({mode="ap-wds"})
	hidden:depends({mode="sta-wds"})

	isolate = s:taboption("advanced", Flag, "isolate", translate("Separate Clients"),
		translate("Prevents client-to-client communication"))
	isolate:depends({mode="ap"})
	s:taboption("advanced", Flag, "bgscan", translate("Background Scan"))

	mp = s:taboption("macfilter", ListValue, "macpolicy", translate("MAC-Address Filter"))
	mp:value("",      translate("disable"))
	mp:value("allow", translate("Allow listed only"))
	mp:value("deny",  translate("Allow all except listed"))

	ml = s:taboption("macfilter", DynamicList, "maclist", translate("MAC-List"))
	ml.datatype = "macaddr"
	ml:depends({macpolicy="allow"})
	ml:depends({macpolicy="deny"})
	nt.mac_hints(function(mac, name) ml:value(mac, "%s (%s)" %{ mac, name }) end)

	s:taboption("advanced", Value, "rate",       translate("Transmission Rate"))
	s:taboption("advanced", Value, "mcast_rate", translate("Multicast Rate"))
	s:taboption("advanced", Value, "frag",       translate("Fragmentation Threshold"))
	s:taboption("advanced", Value, "rts",        translate("RTS/CTS Threshold"))
	s:taboption("advanced", Value, "minrate",    translate("Minimum Rate"))
	s:taboption("advanced", Value, "maxrate",    translate("Maximum Rate"))
	s:taboption("advanced", Flag,  "compression", translate("Compression"))
	s:taboption("advanced", Flag,  "bursting",   translate("Frame Bursting"))
	s:taboption("advanced", Flag,  "turbo",      translate("Turbo Mode"))
	s:taboption("advanced", Flag,  "ff",         translate("Fast Frames"))
	s:taboption("advanced", Flag,  "wmm",        translate("WMM Mode"))
	s:taboption("advanced", Flag,  "xr",         translate("XR Support"))
	s:taboption("advanced", Flag,  "ar",         translate("AR Support"))

	local swm = s:taboption("advanced", Flag, "sw_merge", translate("Disable HW-Beacon timer"))
	swm:depends({mode="adhoc"})

	local nos = s:taboption("advanced", Flag, "nosbeacon", translate("Disable HW-Beacon timer"))
	nos:depends({mode="sta"})
	nos:depends({mode="sta-wds"})

	local probereq = s:taboption("advanced", Flag, "probereq", translate("Do not send probe responses"))
	probereq.enabled  = "0"
	probereq.disabled = "1"
end


-------------------- Broadcom Interface ----------------------
--
-- brcmwifi UCI iface fields used here:
--   mode        = "ap" | "sta" | "adhoc" | "wds" | "monitor"
--   ssid        = string
--   hidden      = "1" | "0"
--   isolate     = "1" | "0"
--   doth        = "1" | "0"   (802.11h)
--   wmm         = "1" | "0"
--   macpolicy   = "" | "allow" | "deny"
--   maclist     = list of MACs
--
-- Encryption fields (all set by encr.write below):
--   encryption  = "none" | "wep" | "psk" | "psk_sae" | "owe"
--   psk_version = "wpa" | "rsn" | "auto" | "sae_only" | "sae_transition" | "owe_only"
--   psk_cipher  = "aes" | "tkip" | "auto"
--   psk_key     = <passphrase>   (WPA/WPA2/WPA2+WPA3)
--   sae_password= <passphrase>   (WPA3-Personal only)
--   wep_key1    = <key>

if hwtype == "brcmwifi" then
	mode:value("wds",     translate("WDS"))
	mode:value("monitor", translate("Monitor"))

	hidden = s:taboption("general", Flag, "hidden",
		translate("Hide <abbr title=\"Extended Service Set Identifier\">ESSID</abbr>"))
	hidden:depends({mode="ap"})
	hidden:depends({mode="adhoc"})
	hidden:depends({mode="wds"})

	isolate = s:taboption("advanced", Flag, "isolate",
		translate("Separate Clients"),
		translate("Prevents client-to-client communication"))
	isolate:depends({mode="ap"})

	s:taboption("advanced", Flag, "doth", "802.11h")
	s:taboption("advanced", Flag, "wmm", translate("WMM Mode"))

	bssid:depends({mode="wds"})
	bssid:depends({mode="adhoc"})

	mp = s:taboption("macfilter", ListValue, "macpolicy", translate("MAC-Address Filter"))
	mp:value("",      translate("disable"))
	mp:value("allow", translate("Allow listed only"))
	mp:value("deny",  translate("Allow all except listed"))

	ml = s:taboption("macfilter", DynamicList, "maclist", translate("MAC-List"))
	ml.datatype = "macaddr"
	ml:depends({macpolicy="allow"})
	ml:depends({macpolicy="deny"})
	nt.mac_hints(function(mac, name) ml:value(mac, "%s (%s)" %{ mac, name }) end)
end


--------------------- HostAP Interface ----------------------

if hwtype == "prism2" then
	mode:value("wds",     translate("WDS"))
	mode:value("monitor", translate("Monitor"))

	hidden = s:taboption("general", Flag, "hidden",
		translate("Hide <abbr title=\"Extended Service Set Identifier\">ESSID</abbr>"))
	hidden:depends({mode="ap"})
	hidden:depends({mode="adhoc"})
	hidden:depends({mode="wds"})

	bssid:depends({mode="sta"})

	mp = s:taboption("macfilter", ListValue, "macpolicy", translate("MAC-Address Filter"))
	mp:value("",      translate("disable"))
	mp:value("allow", translate("Allow listed only"))
	mp:value("deny",  translate("Allow all except listed"))
	ml = s:taboption("macfilter", DynamicList, "maclist", translate("MAC-List"))
	ml:depends({macpolicy="allow"})
	ml:depends({macpolicy="deny"})
	nt.mac_hints(function(mac, name) ml:value(mac, "%s (%s)" %{ mac, name }) end)

	s:taboption("advanced", Value, "rate", translate("Transmission Rate"))
	s:taboption("advanced", Value, "frag", translate("Fragmentation Threshold"))
	s:taboption("advanced", Value, "rts",  translate("RTS/CTS Threshold"))
end


------------------- WiFi Encryption -------------------
--
-- LuCI presents a single "Encryption" dropdown.  For brcmwifi the value
-- space does not map 1:1 to the UCI encryption field because brcmwifi
-- splits mode, version and cipher into three separate UCI keys.
--
-- Canonical internal values used by this form (encr dropdown):
--   "none"         -> encryption=none
--   "wep-open"     -> encryption=wep  (open system)
--   "wep-shared"   -> encryption=wep  (shared key)
--   "psk"          -> encryption=psk  psk_version=wpa   psk_cipher=auto  (WPA-Personal)
--   "psk2"         -> encryption=psk  psk_version=rsn   psk_cipher=aes   (WPA2-Personal)
--   "psk+psk2"     -> encryption=psk  psk_version=auto  psk_cipher=auto  (WPA/WPA2 mixed)
--   "sae"          -> encryption=psk_sae  psk_version=sae_only   psk_cipher=aes  (WPA3-Personal)
--   "sae-mixed"    -> encryption=psk_sae  psk_version=sae_transition  psk_cipher=aes  (WPA2/WPA3 transition)
--   "owe"          -> encryption=owe  psk_version=owe_only   (Enhanced Open)
--   "wpa"          -> encryption=wpa  wpa_version=wpa   wpa_cipher=auto  (WPA-Enterprise)
--   "wpa2"         -> encryption=wpa  wpa_version=rsn   wpa_cipher=aes   (WPA2-Enterprise)
--
-- cfgvalue reconstructs the canonical value from the three UCI fields.
-- write   splits the canonical value back into the three UCI fields.

encr = s:taboption("encryption", ListValue, "encryption", translate("Encryption"))
encr.override_values  = true
encr.override_depends = true
encr:depends({mode="ap"})
encr:depends({mode="sta"})
encr:depends({mode="adhoc"})
encr:depends({mode="ahdemo"})
encr:depends({mode="ap-wds"})
encr:depends({mode="sta-wds"})
encr:depends({mode="mesh"})

-- cipher is only exposed for mac80211/atheros; brcmwifi manages cipher
-- internally via psk_cipher written by encr.write.
cipher = s:taboption("encryption", ListValue, "cipher", translate("Cipher"))
cipher:depends({encryption="wpa"})
cipher:depends({encryption="wpa2"})
cipher:depends({encryption="psk"})
cipher:depends({encryption="psk2"})
cipher:depends({encryption="wpa-mixed"})
cipher:depends({encryption="psk-mixed"})
cipher:value("auto",      translate("auto"))
cipher:value("ccmp",      translate("Force CCMP (AES)"))
cipher:value("tkip",      translate("Force TKIP"))
cipher:value("tkip+ccmp", translate("Force TKIP and CCMP (AES)"))


-- cfgvalue: read the three brcmwifi UCI fields and return the canonical
-- dropdown value.  Falls back to the raw field for non-brcmwifi drivers.
function encr.cfgvalue(self, section)
	if hwtype ~= "brcmwifi" then
		local v = tostring(ListValue.cfgvalue(self, section))
		if v == "wep" then return "wep-open" end
		if v and v:match("%+") then return (v:gsub("%+.+$", "")) end
		return v
	end

	local enc = m.uci:get("wireless", section, "encryption") or "none"
	local ver = m.uci:get("wireless", section, "psk_version") or ""

	if enc == "none"    then return "none"
	elseif enc == "wep" then return "wep-open"
	elseif enc == "owe" then return "owe"
	elseif enc == "psk_sae" then
		if ver == "sae_only"       then return "sae"
		elseif ver == "sae_transition" then return "sae-mixed"
		else                            return "sae" end
	elseif enc == "psk" then
		if ver == "wpa"  then return "psk"
		elseif ver == "rsn"  then return "psk2"
		elseif ver == "auto" then return "psk+psk2"
		else                      return "psk+psk2" end
	elseif enc == "wpa" then
		local wver = m.uci:get("wireless", section, "wpa_version") or ""
		if wver == "rsn" then return "wpa2"
		else                  return "wpa" end
	end
	return "none"
end

-- write: split the canonical dropdown value into the three brcmwifi UCI
-- fields.  For non-brcmwifi drivers preserve the original behaviour of
-- concatenating the cipher suffix.
function encr.write(self, section, value)
	local e = tostring(encr:formvalue(section))
	local c = tostring(cipher:formvalue(section) or "")

	-- Clean up keys that belong to the old mode
	m.uci:delete("wireless", section, "psk_version")
	m.uci:delete("wireless", section, "psk_cipher")
	m.uci:delete("wireless", section, "wpa_version")
	m.uci:delete("wireless", section, "wpa_cipher")

	if hwtype == "brcmwifi" then
		if e == "none" then
			m.uci:set("wireless", section, "encryption", "none")
			m.uci:delete("wireless", section, "psk_key")
			m.uci:delete("wireless", section, "sae_password")

		elseif e == "wep-open" or e == "wep-shared" then
			m.uci:set("wireless", section, "encryption", "wep")

		elseif e == "psk" then
			-- WPA-Personal
			m.uci:set("wireless", section, "encryption",  "psk")
			m.uci:set("wireless", section, "psk_version", "wpa")
			m.uci:set("wireless", section, "psk_cipher",  "auto")
			m.uci:delete("wireless", section, "sae_password")

		elseif e == "psk2" then
			-- WPA2-Personal
			m.uci:set("wireless", section, "encryption",  "psk")
			m.uci:set("wireless", section, "psk_version", "rsn")
			m.uci:set("wireless", section, "psk_cipher",  "aes")
			m.uci:delete("wireless", section, "sae_password")

		elseif e == "psk+psk2" then
			-- WPA/WPA2 mixed
			m.uci:set("wireless", section, "encryption",  "psk")
			m.uci:set("wireless", section, "psk_version", "auto")
			m.uci:set("wireless", section, "psk_cipher",  "auto")
			m.uci:delete("wireless", section, "sae_password")

		elseif e == "sae" then
			-- WPA3-Personal (SAE only)
			m.uci:set("wireless", section, "encryption",  "psk_sae")
			m.uci:set("wireless", section, "psk_version", "sae_only")
			m.uci:set("wireless", section, "psk_cipher",  "aes")
			-- sae_password is written by the saekey widget below

		elseif e == "sae-mixed" then
			-- WPA2/WPA3 transition mode
			m.uci:set("wireless", section, "encryption",  "psk_sae")
			m.uci:set("wireless", section, "psk_version", "sae_transition")
			m.uci:set("wireless", section, "psk_cipher",  "aes")

		elseif e == "owe" then
			-- Enhanced Open (OWE)
			m.uci:set("wireless", section, "encryption",  "owe")
			m.uci:set("wireless", section, "psk_version", "owe_only")
			m.uci:delete("wireless", section, "psk_key")
			m.uci:delete("wireless", section, "sae_password")

		elseif e == "wpa" then
			-- WPA-Enterprise
			m.uci:set("wireless", section, "encryption",  "wpa")
			m.uci:set("wireless", section, "wpa_version", "wpa")
			m.uci:set("wireless", section, "wpa_cipher",  "auto")
			m.uci:delete("wireless", section, "psk_key")
			m.uci:delete("wireless", section, "sae_password")

		elseif e == "wpa2" then
			-- WPA2-Enterprise
			m.uci:set("wireless", section, "encryption",  "wpa")
			m.uci:set("wireless", section, "wpa_version", "rsn")
			m.uci:set("wireless", section, "wpa_cipher",  "aes")
			m.uci:delete("wireless", section, "psk_key")
			m.uci:delete("wireless", section, "sae_password")
		end
		return
	end

	-- non-brcmwifi: original cipher-concatenation logic
	if e == "wpa" or e == "wpa2" then
		m.uci:delete("wireless", section, "psk_key")
	end
	if e and (c == "tkip" or c == "ccmp" or c == "tkip+ccmp") then
		e = e .. "+" .. c
	end
	m.uci:set("wireless", section, "encryption", e)
end

function cipher.cfgvalue(self, section)
	-- brcmwifi stores cipher separately; don't try to parse a + value.
	if hwtype == "brcmwifi" then
		return m.uci:get("wireless", section, "psk_cipher") or "auto"
	end
	local v = tostring(ListValue.cfgvalue(encr, section))
	if v and v:match("%+") then
		v = v:gsub("^[^%+]+%+", "")
		if v == "aes"          then v = "ccmp"
		elseif v == "tkip+aes"     then v = "tkip+ccmp"
		elseif v == "aes+tkip"     then v = "tkip+ccmp"
		elseif v == "ccmp+tkip"    then v = "tkip+ccmp" end
	end
	return v
end

function cipher.write(self, section)
	return encr:write(section)
end


-- Encryption dropdown entries
encr:value("none", "No Encryption")
encr:value("wep-open",   translate("WEP Open System"),
	{mode="ap"}, {mode="sta"}, {mode="ap-wds"}, {mode="sta-wds"},
	{mode="adhoc"}, {mode="ahdemo"}, {mode="wds"})
encr:value("wep-shared", translate("WEP Shared Key"),
	{mode="ap"}, {mode="sta"}, {mode="ap-wds"}, {mode="sta-wds"},
	{mode="adhoc"}, {mode="ahdemo"}, {mode="wds"})

if hwtype == "atheros" or hwtype == "mac80211" or hwtype == "prism2" then
	local supplicant  = fs.access("/usr/sbin/wpa_supplicant")
	local hostapd     = fs.access("/usr/sbin/hostapd")
	local has_ap_eap  = (os.execute("hostapd -veap >/dev/null 2>/dev/null") == 0)
	local has_sta_eap = (os.execute("wpa_supplicant -veap >/dev/null 2>/dev/null") == 0)

	if hostapd and supplicant then
		encr:value("psk",       "WPA-PSK",              {mode="ap"}, {mode="sta"}, {mode="ap-wds"}, {mode="sta-wds"})
		encr:value("psk2",      "WPA2-PSK",             {mode="ap"}, {mode="sta"}, {mode="ap-wds"}, {mode="sta-wds"})
		encr:value("psk-mixed", "WPA-PSK/WPA2-PSK Mixed Mode", {mode="ap"}, {mode="sta"}, {mode="ap-wds"}, {mode="sta-wds"})
		if has_ap_eap and has_sta_eap then
			encr:value("wpa",  "WPA-EAP",  {mode="ap"}, {mode="sta"}, {mode="ap-wds"}, {mode="sta-wds"})
			encr:value("wpa2", "WPA2-EAP", {mode="ap"}, {mode="sta"}, {mode="ap-wds"}, {mode="sta-wds"})
		end
	elseif hostapd and not supplicant then
		encr:value("psk",       "WPA-PSK",              {mode="ap"}, {mode="ap-wds"})
		encr:value("psk2",      "WPA2-PSK",             {mode="ap"}, {mode="ap-wds"})
		encr:value("psk-mixed", "WPA-PSK/WPA2-PSK Mixed Mode", {mode="ap"}, {mode="ap-wds"})
		if has_ap_eap then
			encr:value("wpa",  "WPA-EAP",  {mode="ap"}, {mode="ap-wds"})
			encr:value("wpa2", "WPA2-EAP", {mode="ap"}, {mode="ap-wds"})
		end
	elseif not hostapd and supplicant then
		encr:value("psk",       "WPA-PSK",              {mode="sta"}, {mode="sta-wds"})
		encr:value("psk2",      "WPA2-PSK",             {mode="sta"}, {mode="sta-wds"})
		encr:value("psk-mixed", "WPA-PSK/WPA2-PSK Mixed Mode", {mode="sta"}, {mode="sta-wds"})
		if has_sta_eap then
			encr:value("wpa",  "WPA-EAP",  {mode="sta"}, {mode="sta-wds"})
			encr:value("wpa2", "WPA2-EAP", {mode="sta"}, {mode="sta-wds"})
		end
	end
	encr.description = translate(
		"WPA-Encryption requires wpa_supplicant (for client mode) or hostapd (for AP " ..
		"and ad-hoc mode) to be installed.")

elseif hwtype == "brcmwifi" then
	-- Personal (PSK/SAE)
	encr:value("psk",       "WPA-Personal (WPA)",        {mode="ap"}, {mode="sta"})
	encr:value("psk2",      "WPA2-Personal",             {mode="ap"}, {mode="sta"})
	encr:value("psk+psk2",  "WPA/WPA2-Personal Mixed",   {mode="ap"}, {mode="sta"})
	encr:value("sae",       "WPA3-Personal",             {mode="ap"}, {mode="sta"})
	encr:value("sae-mixed", "WPA2/WPA3-Personal (Transition)", {mode="ap"}, {mode="sta"})
	-- Enhanced Open
	encr:value("owe",       "Enhanced Open (OWE)",       {mode="ap"}, {mode="sta"})
	-- Enterprise
	encr:value("wpa",       "WPA-Enterprise",            {mode="ap"}, {mode="sta"})
	encr:value("wpa2",      "WPA2-Enterprise",           {mode="ap"}, {mode="sta"})
end


-- RADIUS fields (Enterprise modes) --------------------------------

auth_server = s:taboption("encryption", Value, "auth_server",
	translate("Radius-Authentication-Server"))
auth_server:depends({mode="ap",     encryption="wpa"})
auth_server:depends({mode="ap",     encryption="wpa2"})
auth_server:depends({mode="ap-wds", encryption="wpa"})
auth_server:depends({mode="ap-wds", encryption="wpa2"})
auth_server.rmempty  = true
auth_server.datatype = "host"

auth_port = s:taboption("encryption", Value, "auth_port",
	translate("Radius-Authentication-Port"), translatef("Default %d", 1812))
auth_port:depends({mode="ap",     encryption="wpa"})
auth_port:depends({mode="ap",     encryption="wpa2"})
auth_port:depends({mode="ap-wds", encryption="wpa"})
auth_port:depends({mode="ap-wds", encryption="wpa2"})
auth_port.rmempty  = true
auth_port.datatype = "port"

auth_secret = s:taboption("encryption", Value, "auth_secret",
	translate("Radius-Authentication-Secret"))
auth_secret:depends({mode="ap",     encryption="wpa"})
auth_secret:depends({mode="ap",     encryption="wpa2"})
auth_secret:depends({mode="ap-wds", encryption="wpa"})
auth_secret:depends({mode="ap-wds", encryption="wpa2"})
auth_secret.rmempty  = true
auth_secret.password = true

acct_server = s:taboption("encryption", Value, "acct_server",
	translate("Radius-Accounting-Server"))
acct_server:depends({mode="ap",     encryption="wpa"})
acct_server:depends({mode="ap",     encryption="wpa2"})
acct_server:depends({mode="ap-wds", encryption="wpa"})
acct_server:depends({mode="ap-wds", encryption="wpa2"})
acct_server.rmempty  = true
acct_server.datatype = "host"

acct_port = s:taboption("encryption", Value, "acct_port",
	translate("Radius-Accounting-Port"), translatef("Default %d", 1813))
acct_port:depends({mode="ap",     encryption="wpa"})
acct_port:depends({mode="ap",     encryption="wpa2"})
acct_port:depends({mode="ap-wds", encryption="wpa"})
acct_port:depends({mode="ap-wds", encryption="wpa2"})
acct_port.rmempty  = true
acct_port.datatype = "port"

acct_secret = s:taboption("encryption", Value, "acct_secret",
	translate("Radius-Accounting-Secret"))
acct_secret:depends({mode="ap",     encryption="wpa"})
acct_secret:depends({mode="ap",     encryption="wpa2"})
acct_secret:depends({mode="ap-wds", encryption="wpa"})
acct_secret:depends({mode="ap-wds", encryption="wpa2"})
acct_secret.rmempty  = true
acct_secret.password = true


-- PSK / WPA2 passphrase field ------------------------------------
--
-- brcmwifi uses psk_key rather than the vanilla 'key' field.
-- WPA3-SAE (sae / sae-mixed) also uses psk_key as the passphrase;
-- encr.write copies it to sae_password during commit.

wpakey = s:taboption("encryption", Value, "_wpa_key", translate("Key"))
wpakey:depends("encryption", "psk")
wpakey:depends("encryption", "psk2")
wpakey:depends("encryption", "psk+psk2")
wpakey:depends("encryption", "psk-mixed")
wpakey:depends("encryption", "sae")
wpakey:depends("encryption", "sae-mixed")
wpakey.datatype  = "wpakey"
wpakey.rmempty   = true
wpakey.password  = true

wpakey.cfgvalue = function(self, section, value)
	-- Prefer psk_key (brcmwifi); fall back to sae_password for pure WPA3
	local key = m.uci:get("wireless", section, "psk_key")
		      or m.uci:get("wireless", section, "sae_password")
	if key == "1" or key == "2" or key == "3" or key == "4" then
		return nil
	end
	return key
end

wpakey.write = function(self, section, value)
	-- Always write psk_key (used by WPA/WPA2 and WPA3 transition)
	self.map.uci:set("wireless", section, "psk_key", value)
	-- For pure WPA3-Personal, also write sae_password
	local enc = m.uci:get("wireless", section, "encryption")
	local ver = m.uci:get("wireless", section, "psk_version")
	if enc == "psk_sae" and ver == "sae_only" then
		self.map.uci:set("wireless", section, "sae_password", value)
	else
		self.map.uci:delete("wireless", section, "sae_password")
	end
	self.map.uci:delete("wireless", section, "key1")
end


-- WEP slot / key fields ------------------------------------------

wepslot = s:taboption("encryption", ListValue, "_wep_key", translate("Used Key Slot"))
wepslot:depends("encryption", "wep-open")
wepslot:depends("encryption", "wep-shared")
wepslot:value("1", translatef("Key #%d", 1))
wepslot:value("2", translatef("Key #%d", 2))
wepslot:value("3", translatef("Key #%d", 3))
wepslot:value("4", translatef("Key #%d", 4))

wepslot.cfgvalue = function(self, section)
	local slot = tonumber(m.uci:get("wireless", section, "psk_key"))
	if not slot or slot < 1 or slot > 4 then return 1 end
	return slot
end

wepslot.write = function(self, section, value)
	self.map.uci:set("wireless", section, "psk_key", value)
end

local slot
for slot = 1, 4 do
	wepkey = s:taboption("encryption", Value, "key" .. slot,
		translatef("Key #%d", slot))
	wepkey:depends("encryption", "wep-open")
	wepkey:depends("encryption", "wep-shared")
	wepkey.datatype  = "wepkey"
	wepkey.rmempty   = true
	wepkey.password  = true

	function wepkey.write(self, section, value)
		if value and (#value == 5 or #value == 13) then
			value = "s:" .. value
		end
		return Value.write(self, section, value)
	end
end


-- EAP fields (mac80211 / atheros / brcmwifi enterprise) -----------

if hwtype == "atheros" or hwtype == "mac80211" or hwtype == "prism2"
   or hwtype == "brcmwifi" then

	nasid = s:taboption("encryption", Value, "nasid", translate("NAS ID"))
	nasid:depends({mode="ap",     encryption="wpa"})
	nasid:depends({mode="ap",     encryption="wpa2"})
	nasid:depends({mode="ap-wds", encryption="wpa"})
	nasid:depends({mode="ap-wds", encryption="wpa2"})
	nasid.rmempty = true

	eaptype = s:taboption("encryption", ListValue, "eap_type", translate("EAP-Method"))
	eaptype:value("tls",  "TLS")
	eaptype:value("ttls", "TTLS")
	eaptype:value("peap", "PEAP")
	eaptype:depends({mode="sta",     encryption="wpa"})
	eaptype:depends({mode="sta",     encryption="wpa2"})
	eaptype:depends({mode="sta-wds", encryption="wpa"})
	eaptype:depends({mode="sta-wds", encryption="wpa2"})

	cacert = s:taboption("encryption", FileUpload, "ca_cert",
		translate("Path to CA-Certificate"))
	cacert:depends({mode="sta",     encryption="wpa"})
	cacert:depends({mode="sta",     encryption="wpa2"})
	cacert:depends({mode="sta-wds", encryption="wpa"})
	cacert:depends({mode="sta-wds", encryption="wpa2"})

	clientcert = s:taboption("encryption", FileUpload, "client_cert",
		translate("Path to Client-Certificate"))
	clientcert:depends({mode="sta",     encryption="wpa"})
	clientcert:depends({mode="sta",     encryption="wpa2"})
	clientcert:depends({mode="sta-wds", encryption="wpa"})
	clientcert:depends({mode="sta-wds", encryption="wpa2"})

	privkey = s:taboption("encryption", FileUpload, "priv_key",
		translate("Path to Private Key"))
	privkey:depends({mode="sta",     eap_type="tls", encryption="wpa2"})
	privkey:depends({mode="sta",     eap_type="tls", encryption="wpa"})
	privkey:depends({mode="sta-wds", eap_type="tls", encryption="wpa2"})
	privkey:depends({mode="sta-wds", eap_type="tls", encryption="wpa"})

	privkeypwd = s:taboption("encryption", Value, "priv_key_pwd",
		translate("Password of Private Key"))
	privkeypwd:depends({mode="sta",     eap_type="tls", encryption="wpa2"})
	privkeypwd:depends({mode="sta",     eap_type="tls", encryption="wpa"})
	privkeypwd:depends({mode="sta-wds", eap_type="tls", encryption="wpa2"})
	privkeypwd:depends({mode="sta-wds", eap_type="tls", encryption="wpa"})

	auth = s:taboption("encryption", Value, "auth", translate("Authentication"))
	auth:value("PAP")
	auth:value("CHAP")
	auth:value("MSCHAP")
	auth:value("MSCHAPV2")
	auth:depends({mode="sta",     eap_type="peap", encryption="wpa2"})
	auth:depends({mode="sta",     eap_type="peap", encryption="wpa"})
	auth:depends({mode="sta",     eap_type="ttls", encryption="wpa2"})
	auth:depends({mode="sta",     eap_type="ttls", encryption="wpa"})
	auth:depends({mode="sta-wds", eap_type="peap", encryption="wpa2"})
	auth:depends({mode="sta-wds", eap_type="peap", encryption="wpa"})
	auth:depends({mode="sta-wds", eap_type="ttls", encryption="wpa2"})
	auth:depends({mode="sta-wds", eap_type="ttls", encryption="wpa"})

	identity = s:taboption("encryption", Value, "identity", translate("Identity"))
	identity:depends({mode="sta",     eap_type="peap", encryption="wpa2"})
	identity:depends({mode="sta",     eap_type="peap", encryption="wpa"})
	identity:depends({mode="sta",     eap_type="ttls", encryption="wpa2"})
	identity:depends({mode="sta",     eap_type="ttls", encryption="wpa"})
	identity:depends({mode="sta-wds", eap_type="peap", encryption="wpa2"})
	identity:depends({mode="sta-wds", eap_type="peap", encryption="wpa"})
	identity:depends({mode="sta-wds", eap_type="ttls", encryption="wpa2"})
	identity:depends({mode="sta-wds", eap_type="ttls", encryption="wpa"})

	password = s:taboption("encryption", Value, "password", translate("Password"))
	password:depends({mode="sta",     eap_type="peap", encryption="wpa2"})
	password:depends({mode="sta",     eap_type="peap", encryption="wpa"})
	password:depends({mode="sta",     eap_type="ttls", encryption="wpa2"})
	password:depends({mode="sta",     eap_type="ttls", encryption="wpa"})
	password:depends({mode="sta-wds", eap_type="peap", encryption="wpa2"})
	password:depends({mode="sta-wds", eap_type="peap", encryption="wpa"})
	password:depends({mode="sta-wds", eap_type="ttls", encryption="wpa2"})
	password:depends({mode="sta-wds", eap_type="ttls", encryption="wpa"})
end

return m