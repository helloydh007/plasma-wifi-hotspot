#!/bin/bash
# 安装/更新：部署后端（root）+ 安装 Plasma 插件（用户级）+ 桌面入口
#
# 用法：bash install.sh
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"

echo "== 1) 部署后端（会弹一次授权框）=="
pkexec bash "$SRC/backend/deploy.sh"

echo
echo "== 2) 同步后端副本进插件包（供插件内“一键修复”）=="
bash "$SRC/sync-backend.sh"

echo
echo "== 3) 安装 Plasma 插件（用户级，无需 root）=="
if kpackagetool6 -t Plasma/Applet -l 2>/dev/null | grep -qx 'org.kde.hotspot'; then
    kpackagetool6 -t Plasma/Applet -u "$SRC/plasmoid"
else
    kpackagetool6 -t Plasma/Applet -i "$SRC/plasmoid"
fi

echo
echo "== 4) 安装桌面入口 =="
install -m 644 "$SRC/backend/org.kde.hotspot.desktop" "$HOME/.local/share/applications/"
kbuildsycoca6 --noincremental >/dev/null 2>&1 || true

echo
echo "== 5) 重启 plasmashell 加载新插件 =="
echo "   （plasmashell 会把插件 QML 缓存在内存里，不重启的话托盘仍在跑旧界面）"
systemctl --user restart plasma-plasmashell.service 2>/dev/null && echo "   已重启" || echo "   重启失败，请手动执行: systemctl --user restart plasma-plasmashell"

echo
cat <<'TXT'
完成。接下来：
  1) 编辑 /etc/kde-hotspot/config，把 SSID/PASS 改成你自己的
     （未设置时后端会拒绝启动热点，不会用默认密码）
  2) 把插件放进托盘：右键面板 → 系统托盘设置 → 条目 → 勾选“Wi-Fi 热点控制”
     或者直接把它拖到面板上（面板上会显示频段/信道文字）
  3) 也可以从应用菜单/KRunner 搜“Wi-Fi 热点控制”打开独立窗口
TXT
