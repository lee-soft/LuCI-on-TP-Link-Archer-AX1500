module("luci.controller.admin.qos_vanilla", package.seeall)

function index()
	local fs = require("nixio.fs")
	if not fs.access("/etc/config/qos_v2") then
		return
	end

	entry({"admin", "network", "qos"},
		cbi("qos/qos"),
		translate("QoS"), 59).dependent = true
end