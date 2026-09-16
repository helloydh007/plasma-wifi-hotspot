#!/bin/bash
# 部署/更新并发热点后端（需要 root：pkexec bash deploy.sh）
#
# 本脚本同时被 KDE 的内置插件包携带（plasmoid 的 backend/ 目录），
# 用于后端缺失或损坏时一键恢复。
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"

echo "== 1) 目录 =="
install -d -m 755 /var/lib/kde-hotspot
[ -d /etc/polkit-1/rules.d ] || { echo "找不到 /etc/polkit-1/rules.d"; exit 1; }
[ -d /usr/share/polkit-1/actions ] || { echo "找不到 polkit actions 目录"; exit 1; }

echo "== 2) 拷贝文件 =="
install -m 755 "$SRC/kde-hotspot-ctl"  /usr/local/sbin/kde-hotspot-ctl
install -m 755 "$SRC/kde-hotspot.sh"   /usr/local/sbin/kde-hotspot.sh
install -m 644 "$SRC/kde-hotspot.service"        /etc/systemd/system/kde-hotspot.service
install -m 644 "$SRC/kde-hotspot-dhcp.service"   /etc/systemd/system/kde-hotspot-dhcp.service
install -m 644 "$SRC/kde-hotspot-normal.service" /etc/systemd/system/kde-hotspot-normal.service
install -m 644 "$SRC/org.kde.hotspotctl.policy"  /usr/share/polkit-1/actions/org.kde.hotspotctl.policy
install -m 644 "$SRC/49-kde-hotspot.rules"       /etc/polkit-1/rules.d/49-kde-hotspot.rules
chown root:polkitd /etc/polkit-1/rules.d/49-kde-hotspot.rules 2>/dev/null || true
ls -l /usr/local/sbin/kde-hotspot-ctl /usr/local/sbin/kde-hotspot.sh \
      /usr/share/polkit-1/actions/org.kde.hotspotctl.policy \
      /etc/polkit-1/rules.d/49-kde-hotspot.rules \
      /etc/systemd/system/kde-hotspot*.service | awk '{print "  "$1" "$3":"$4" "$NF}'

echo "== 3) 重载 systemd 与 polkit =="
systemctl daemon-reload
# polkit 会自动监测 rules.d 变化（inotify），无需重启服务；这里只做提示
echo "  systemd 已重载（polkit 规则会自动生效）"

echo "== 4) 配置文件（缺失时用示例生成；SSID/PASS 需自行修改）=="
install -d -m 755 /etc/kde-hotspot
if [ ! -e /etc/kde-hotspot/config ]; then
    install -m 644 "$SRC/config.example" /etc/kde-hotspot/config
    echo "  已生成 /etc/kde-hotspot/config（占位值，请修改 SSID/PASS）"
fi
install -m 644 "$SRC/dnsmasq.conf" /etc/kde-hotspot/dnsmasq.conf
# 配置里有热点密码：root 属主 + 640，读取权限授予网络管理组。
# 目的：插件的 status 只是只读查询，不该每次都 pkexec（fork root + 建 polkit 会话）；
# 授予该组后插件即可免特权读到 SSID/密码/MODE。该用户集合与 polkit 规则
# （sudo/netdev 组免密执行 ctl）一致，因此不降低安全等级。
CONF_GROUP=""
for g in netdev sudo wheel; do
    if getent group "$g" >/dev/null 2>&1; then CONF_GROUP="$g"; break; fi
done
if [ -n "$CONF_GROUP" ]; then
    echo "$CONF_GROUP" > /var/lib/kde-hotspot/conf.group
    chgrp "$CONF_GROUP" /etc/kde-hotspot/config 2>/dev/null || true
    chmod 640 /etc/kde-hotspot/config
    echo "  配置权限 root:$CONF_GROUP 640（该组可只读，供插件免特权读状态）"
else
    chmod 600 /etc/kde-hotspot/config
    rm -f /var/lib/kde-hotspot/conf.group
    echo "  未找到 netdev/sudo/wheel 组，配置保持 600（插件读不到密码，其余功能正常）"
fi
# 无敏感信息的状态标记设为可读（供免特权 status 使用）
chmod 0644 /var/lib/kde-hotspot/disabled /var/lib/kde-hotspot/fallback 2>/dev/null || true

echo "== 4b) 配置里补上 MODE 键（默认并发模式）=="
if ! grep -q '^MODE=' /etc/kde-hotspot/config 2>/dev/null; then
    printf 'MODE=concurrent    # concurrent=并发模式(保持Wi-Fi) / normal=普通模式(断开Wi-Fi)\n' >> /etc/kde-hotspot/config
    echo "  已追加 MODE=concurrent"
else
    echo "  MODE 已存在: $(grep '^MODE=' /etc/kde-hotspot/config)"
fi

echo "== 4c) 让 NetworkManager 不接管 ap0（并发模式必需）=="
install -d -m 755 /etc/NetworkManager/conf.d
install -m 644 "$SRC/99-kde-hotspot-ap0.conf" /etc/NetworkManager/conf.d/99-kde-hotspot-ap0.conf
nmcli general reload 2>/dev/null || true
echo "  已安装 /etc/NetworkManager/conf.d/99-kde-hotspot-ap0.conf"

echo "== 5) 让并发模式服务读到新脚本 =="
systemctl restart kde-hotspot.service kde-hotspot-dhcp.service 2>/dev/null || true
systemctl is-active kde-hotspot.service kde-hotspot-dhcp.service | tr '\n' ' '; echo

echo "== 6) 状态 =="
/usr/local/sbin/kde-hotspot-ctl status
echo "部署完成"
