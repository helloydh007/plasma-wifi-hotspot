#!/bin/bash
# 部署/更新并发热点后端（需要 root：pkexec bash deploy.sh）
#
# 本脚本同时被 ZCode 的内置插件包携带（plasmoid 的 backend/ 目录），
# 用于后端缺失或损坏时一键恢复。
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"

echo "== 1) 目录 =="
install -d -m 755 /var/lib/zcode-hotspot
[ -d /etc/polkit-1/rules.d ] || { echo "找不到 /etc/polkit-1/rules.d"; exit 1; }
[ -d /usr/share/polkit-1/actions ] || { echo "找不到 polkit actions 目录"; exit 1; }

echo "== 2) 拷贝文件 =="
install -m 755 "$SRC/zcode-hotspot-ctl"  /usr/local/sbin/zcode-hotspot-ctl
install -m 755 "$SRC/zcode-hotspot.sh"   /usr/local/sbin/zcode-hotspot.sh
install -m 644 "$SRC/zcode-hotspot.service"        /etc/systemd/system/zcode-hotspot.service
install -m 644 "$SRC/zcode-hotspot-dhcp.service"   /etc/systemd/system/zcode-hotspot-dhcp.service
install -m 644 "$SRC/zcode-hotspot-normal.service" /etc/systemd/system/zcode-hotspot-normal.service
install -m 644 "$SRC/org.zcode.hotspotctl.policy"  /usr/share/polkit-1/actions/org.zcode.hotspotctl.policy
install -m 644 "$SRC/49-zcode-hotspot.rules"       /etc/polkit-1/rules.d/49-zcode-hotspot.rules
chown root:polkitd /etc/polkit-1/rules.d/49-zcode-hotspot.rules 2>/dev/null || true
ls -l /usr/local/sbin/zcode-hotspot-ctl /usr/local/sbin/zcode-hotspot.sh \
      /usr/share/polkit-1/actions/org.zcode.hotspotctl.policy \
      /etc/polkit-1/rules.d/49-zcode-hotspot.rules \
      /etc/systemd/system/zcode-hotspot*.service | awk '{print "  "$1" "$3":"$4" "$NF}'

echo "== 3) 重载 systemd 与 polkit =="
systemctl daemon-reload
# polkit 会自动监测 rules.d 变化（inotify），无需重启服务；这里只做提示
echo "  systemd 已重载（polkit 规则会自动生效）"

echo "== 4) 配置文件（缺失时用示例生成；SSID/PASS 需自行修改）=="
install -d -m 755 /etc/zcode-hotspot
if [ ! -e /etc/zcode-hotspot/config ]; then
    install -m 644 "$SRC/config.example" /etc/zcode-hotspot/config
    echo "  已生成 /etc/zcode-hotspot/config（占位值，请修改 SSID/PASS）"
fi
install -m 644 "$SRC/dnsmasq.conf" /etc/zcode-hotspot/dnsmasq.conf
# 配置里有热点密码，收紧权限到 600（脚本以 root 运行，不受影响）
chmod 600 /etc/zcode-hotspot/config

echo "== 4b) 配置里补上 MODE 键（默认并发模式）=="
if ! grep -q '^MODE=' /etc/zcode-hotspot/config 2>/dev/null; then
    printf 'MODE=concurrent    # concurrent=并发模式(保持Wi-Fi) / normal=普通模式(断开Wi-Fi)\n' >> /etc/zcode-hotspot/config
    echo "  已追加 MODE=concurrent"
else
    echo "  MODE 已存在: $(grep '^MODE=' /etc/zcode-hotspot/config)"
fi

echo "== 5) 让并发模式服务读到新脚本 =="
systemctl restart zcode-hotspot.service zcode-hotspot-dhcp.service 2>/dev/null || true
systemctl is-active zcode-hotspot.service zcode-hotspot-dhcp.service | tr '\n' ' '; echo

echo "== 6) 状态 =="
/usr/local/sbin/zcode-hotspot-ctl status
echo "部署完成"
