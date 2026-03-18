module("luci.controller.admin.openvpn_vanilla", package.seeall)

function index()
	local fs = require("nixio.fs")
	if not fs.access("/usr/sbin/openvpn") then
		return
	end

	entry({"admin", "services", "openvpn"}, cbi("openvpn"), "OpenVPN", 10).index = true
	entry({"admin", "services", "openvpn", "basic"},    cbi("openvpn-basic"),    nil).leaf = true
	entry({"admin", "services", "openvpn", "advanced"}, cbi("openvpn-advanced"), nil).leaf = true
	entry({"admin", "services", "openvpn", "file"},     form("openvpn-file"),    nil).leaf = true
	entry({"admin", "services", "openvpn", "upload"},   call("ovpn_upload")).leaf = true

end

function ovpn_upload()
	local dbg = io.open("/tmp/upload-debug.log", "w")
	local function dlog(s) dbg:write(tostring(s) .. "\n"); dbg:flush() end
	dlog("ovpn_upload started")

	local fs      = require("nixio.fs")
	local http    = require("luci.http")
	local uci     = require("luci.model.uci").cursor()
	local basedir = "/etc/openvpn"

	-- get name from URL path (last component)
	local path = http.getenv("PATH_INFO") or ""
	local name = path:match("/([^/]+)$")
	dlog("name from URL=" .. tostring(name))

	local file = nil
	local fp   = nil

	if name and #name > 0 then
		file = basedir .. "/" .. name .. ".ovpn"
	end

	http.setfilehandler(
		function(meta, chunk, eof)
			dlog("handler meta.name=" .. tostring(meta and meta.name) ..
				" chunk=" .. tostring(chunk and #chunk) ..
				" eof=" .. tostring(eof))
			if meta and meta.name == "ovpn_file" then
				if not fp and file then
					if not fs.stat(basedir) then fs.mkdir(basedir) end
					dlog("opening file=" .. file)
					fp = io.open(file, "w")
				end
			end
			if fp and chunk and meta and meta.name == "ovpn_file" then
				fp:write(chunk:gsub("\r\n", "\n"))
			end
			if eof and fp then

				fp:close()
				fp = nil
				local content = fs.readfile(file)
				if content then
					-- remove bare numeric lines (chunked encoding artifacts)
					content = content:gsub("\n%d+\n", "\n"):gsub("\n%d+$", "")
					fs.writefile(file, content)
				end

			end			
		end
	)

	http.formvalue("ovpn_file")
	dlog("after formvalue: name=" .. tostring(name) .. " file=" .. tostring(file))

	if name and file and fs.access(file) then
		local uci_name = name:gsub("-", "_")
		uci:load("openvpn")
		if not uci:get("openvpn", uci_name) then
			uci:set("openvpn", uci_name, "openvpn")
			uci:set("openvpn", uci_name, "config", file)
			uci:set("openvpn", uci_name, "enabled", "1")
			uci:set("openvpn", uci_name, "client", "1")
			uci:set("openvpn", uci_name, "dev", "tun")
			-- set auth file path (user can populate via Edit page)
			local auth_file = basedir .. "/" .. uci_name .. ".auth"
			uci:set("openvpn", uci_name, "auth_user_pass", auth_file)
			uci:save("openvpn")
			uci:commit("openvpn")
		end
	end

	dbg:close()
	http.redirect(luci.dispatcher.build_url("admin/services/openvpn"))
end
