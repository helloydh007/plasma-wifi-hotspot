#!/bin/bash
# 安装/更新：部署后端（root）+ 安装 Plasma 插件（用户级）+ 桌面入口
#
# 用法：bash install.sh
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"

echo "== 1) 部署后端（会弹一次授权框）=="
pkexec bash "$SRC/backend/deploy.sh"

echo
echo "== 2) 把后端副本放进插件包（供插件内“一键修复”使用）=="
install -d -m 755 "$SRC/plasmoid/contents/backend"
install -m 755 "$SRC/backend/zcode-hotspot-ctl" "$SRC/backend/zcode-hotspot.sh" \
               "$SRC/backend/deploy.sh" "$SRC/plasmoid/contents/backend/"
install -m 644 "$SRC"/backend/*.service "$SRC"/backend/*.policy "$SRC"/backend/*.rules \
               "$SRC"/backend/*.desktop "$SRC"/backend/config.example "$SRC/plasmoid/contents/backend/"

echo
echo "== 3) 安装 Plasma 插件（用户级，无需 root）=="
if kpackagetool6 -t Plasma/Applet -l 2>/dev/null | grep -qx 'org.zcode.hotspot'; then
    kpackagetool6 -t Plasma/Applet -u "$SRC/plasmoid"
else
    kpackagetool6 -t Plasma/Applet -i "$SRC/plasmoid"
fi

echo
echo "== 4) 安装桌面入口 =="
install -m 644 "$SRC/backend/org.zcode.hotspot.desktop" "$HOME/.local/share/applications/"
kbuildsycoca6 --noincremental >/dev/null 2>&1 || true

echo
cat <<'TXT'
完成。接下来：
  1) 编辑 /etc/zcode-hotspot/config，把 SSID/PASS 改成你自己的
     （未设置时后端会拒绝启动热点，不会用默认密码）
  2) 把插件放进托盘：右键面板 → 系统托盘设置 → 条目 → 勾选“Wi-Fi 热点控制”
     或者直接把它拖到面板上（面板上会显示频段/信道文字）
  3) 也可以从应用菜单/KRunner 搜“Wi-Fi 热点控制”打开独立窗口
TXT
