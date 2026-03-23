--[[
LuCI QoS page for TP-Link Archer AX10
Fronts the qos_v2 UCI config using the router's built-in HTB+SFQ kernel support.
Based on vanilla luci-app-qos CBI style for LuCI 0.11.1 (Attitude Adjustment)
]]--

m = Map("qos_v2", translate("Quality of Service"),
	translate("With <abbr title=\"Quality of Service\">QoS</abbr> you can " ..
		"shape upload and download bandwidth and prioritise traffic " ..
		"per device using HTB + SFQ queuing built into the router kernel."))

--
-- Section 1: Global Settings
--
s = m:section(NamedSection, "settings", "global", translate("Global Settings"))
s.addremove = false
s.anonymous = false

e = s:option(Flag, "enable", translate("Enable QoS"))
e.rmempty = false
e.default = "off"
e.enabled = "on"
e.disabled = "off"

dl = s:option(Value, "down_band", translate("Download speed (Mbit/s)"),
	translate("Your ISP's download speed. Used to shape inbound traffic on br-lan."))
dl.datatype = "and(uinteger,min(1))"
dl.rmempty = false
dl.placeholder = "100"

ul = s:option(Value, "up_band", translate("Upload speed (Mbit/s)"),
	translate("Your ISP's upload speed. Used to shape outbound traffic on WAN."))
ul.datatype = "and(uinteger,min(1))"
ul.rmempty = false
ul.placeholder = "20"

hi = s:option(Value, "high", translate("High priority weight (%)"),
	translate("Percentage of bandwidth reserved for high priority traffic. " ..
		"Remaining percentage goes to low priority. Both are scaled proportionally."))
hi.datatype = "and(uinteger,min(1),max(99))"
hi.default = "90"
hi.rmempty = false

lo = s:option(Value, "low", translate("Low priority weight (%)"),
	translate("Percentage of bandwidth for low priority traffic. High + Low do not " ..
		"need to add up to 100, they are used as relative weights."))
lo.datatype = "and(uinteger,min(1),max(99))"
lo.default = "10"
lo.rmempty = false

du = s:option(ListValue, "down_unit", translate("Download unit"))
du:value("mbps", "Mbit/s")
du:value("kbps", "Kbit/s")
du.default = "mbps"

uu = s:option(ListValue, "up_unit", translate("Upload unit"))
uu:value("mbps", "Mbit/s")
uu:value("kbps", "Kbit/s")
uu.default = "mbps"

--
-- Section 2: Per-device priority
--
c = m:section(TypedSection, "client", translate("Device Priority"),
	translate("Mark specific devices as high priority. Traffic from these MAC addresses " ..
		"will be placed in the high priority HTB class. All other devices are low priority by default."))
c.template = "cbi/tblsection"
c.anonymous = true
c.addremove = true

mac = c:option(Value, "mac", translate("MAC Address"),
	translate("Device MAC address, e.g. AA:BB:CC:DD:EE:FF"))
mac.datatype = "macaddr"
mac.rmempty = false

prio = c:option(Flag, "prio", translate("High Priority"))
prio.rmempty = false
prio.enabled = "on"
prio.disabled = "off"
prio.default = "on"

time = c:option(Value, "prio_time", translate("Expires"),
	translate("Unix timestamp when priority expires, or -1 for never."))
time.default = "-1"
time.rmempty = true

m.on_after_commit = function(self)
	os.execute("/etc/init.d/qos restart >/dev/null 2>&1 &")
end

return m
