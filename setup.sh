#!/bin/sh
echo "Cleaning up existing processes..."
kill -9 $(pgrep uhttpd_vanilla) 2>/dev/null
kill -9 $(pgrep dropbear_vanilla) 2>/dev/null
sleep 1

echo "Downloading repo zip..."
curl -4 -L -k -o /tmp/luci-deploy.zip https://github.com/lee-soft/LuCI-on-TP-Link-Archer-AX1500/archive/refs/heads/main.zip

echo "Extracting..."
cd /tmp
unzip -o luci-deploy.zip

echo "Moving files from container folder..."
cp -r /tmp/LuCI-on-TP-Link-Archer-AX1500-main/luci-lua/* /usr/lib/lua/luci/
cp -r /tmp/LuCI-on-TP-Link-Archer-AX1500-main/www-vanilla /tmp/www-vanilla
cp /tmp/LuCI-on-TP-Link-Archer-AX1500-main/uhttpd_vanilla /tmp/uhttpd_vanilla
cp /tmp/LuCI-on-TP-Link-Archer-AX1500-main/dropbear_vanilla /tmp/dropbear_vanilla

echo "Fixing permissions..."
chmod +x /tmp/www-vanilla/cgi-bin/luci
chmod +x /tmp/dropbear_vanilla
chmod +x /tmp/uhttpd_vanilla

echo "Setting password..."
echo 'root::0:0:99999:7:::' > /etc/shadow

echo "Configuring luci..."
uci set luci.main=core
uci set luci.main.mediaurlbase=/luci-static/openwrt.org
uci set luci.main.resourcebase=/luci-static/resources
uci set luci.main.lang=auto
uci set luci.themes=internal
uci set luci.themes.OpenWrt=/luci-static/openwrt.org
uci commit luci
sed -i '/killersteel/d' /etc/config/luci

echo "Installing OpenVPN init script..."
cp /tmp/LuCI-on-TP-Link-Archer-AX1500-main/openvpn-init.d /etc/init.d/openvpn
chmod +x /etc/init.d/openvpn

echo "Setting up OpenVPN recipes..."
cat > /etc/config/openvpn_recipes << 'EOF'
config openvpn_recipe 'client'
	option _description 'Custom OpenVPN Client'
	option dev 'tun'
	option proto 'udp'
	option resolv_retry 'infinite'
	option nobind '1'
	option persist_key '1'
	option persist_tun '1'
	option verb '3'
EOF

echo "Clearing LuCI cache..."
rm -f /tmp/luci-indexcache-vanilla
rm -f /tmp/luci-modulecache/*

echo "Starting dropbear SSH on port 2222..."
(/tmp/dropbear_vanilla -p 2222 -R -E </dev/null >/dev/null 2>&1) &

echo "Starting vanilla uhttpd on port 8080..."
(/tmp/uhttpd_vanilla -p 8080 -h /tmp/www-vanilla -x /cgi-bin -f </dev/null >/dev/null 2>&1) &

echo "Pre-warming LuCI cache..."
rm -f /tmp/luci-indexcache-vanilla
lua -e '
require "luci.dispatcher"
luci.dispatcher.indexcache = "/tmp/luci-indexcache-vanilla"
luci.dispatcher.createindex()
' 2>/dev/null
echo "Done! LuCI at http://$(uci get network.lan.ipaddr):8080/cgi-bin/luci"