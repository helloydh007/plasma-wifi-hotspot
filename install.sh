#!/bin/bash
# 安装/更新：部署后端（root）+ 安装 Plasma 插件（用户级）+ 桌面入口
#
# 用法：bash install.sh [--no-restart]
#   --no-restart  即使插件内容有变化也不重启 plasmashell（注销重登后同样生效）
#   --restart     强制重启 plasmashell
#
# 关于 plasmashell 重启：plasmashell 会把插件 QML 读进内存，更新插件后必须重启
# （或注销重登）才会加载新界面。但重启会重建所有小组件，只在内存里保存的开关会
# 复位——例如电池小程序的“阻止睡眠/咖啡因”、第三方插件未持久化的状态。
# 因此这里只在**插件内容确实变化时**才重启：仅后端改动（脚本/单元/polkit）不会
# 触发重启。
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"
HASHFILE="$HOME/.local/share/kde-hotspot/plasmoid.hash"

RESTART=auto
for a in "$@"; do
    case "$a" in
        --no-restart) RESTART=no ;;
        --restart)    RESTART=yes ;;
        -h|--help)    sed -n '3,5p' "$0"; exit 0 ;;
        *) echo "未知参数：$a（可用：--no-restart / --restart）" >&2; exit 2 ;;
    esac
done

# 只对"会影响已加载界面"的文件取指纹（QML/元数据/配置模式/翻译）；
# 插件包内的后端副本（contents/backend）不影响界面，变化时无需重启。
plasmoid_hash(){
    ( cd "$SRC/plasmoid" && \
      find metadata.json contents/ui contents/config contents/locale -type f 2>/dev/null \
        | sort | xargs sha256sum | sha256sum | cut -d' ' -f1 )
}

echo "== 1) 部署后端（会弹一次授权框）=="
pkexec bash "$SRC/backend/deploy.sh"

echo
echo "== 2) 同步后端副本进插件包（供插件内“一键修复”）=="
bash "$SRC/sync-backend.sh"

echo
echo "== 3) 安装 Plasma 插件（用户级，无需 root）=="
NEW_HASH="$(plasmoid_hash)"
OLD_HASH=""
[ -r "$HASHFILE" ] && OLD_HASH="$(cat "$HASHFILE" 2>/dev/null)"
NEED_RESTART=yes

if [ "$NEW_HASH" = "$OLD_HASH" ] && kpackagetool6 -t Plasma/Applet -l 2>/dev/null | grep -qx 'org.kde.hotspot'; then
    echo "   插件内容与上次安装一致 → 跳过重装（界面无需刷新）"
    NEED_RESTART=no
else
    if kpackagetool6 -t Plasma/Applet -l 2>/dev/null | grep -qx 'org.kde.hotspot'; then
        kpackagetool6 -t Plasma/Applet -u "$SRC/plasmoid"
    else
        kpackagetool6 -t Plasma/Applet -i "$SRC/plasmoid"
    fi
    mkdir -p "$(dirname "$HASHFILE")"
    printf '%s\n' "$NEW_HASH" > "$HASHFILE"
fi

echo
echo "== 4) 安装桌面入口 =="
install -m 644 "$SRC/backend/org.kde.hotspot.desktop" "$HOME/.local/share/applications/"
kbuildsycoca6 --noincremental >/dev/null 2>&1 || true

echo
echo "== 5) 刷新界面 =="
if [ "$NEED_RESTART" = no ]; then
    echo "   插件未变化，无需重启 plasmashell"
elif [ "$RESTART" = no ]; then
    cat <<'TXT'
   插件已更新，但界面要重启 plasmashell（或注销重登）才会加载新 QML。
   已指定 --no-restart → 跳过重启；需要时执行：
       systemctl --user restart plasma-plasmashell
TXT
else
    cat <<'TXT'
   插件已更新，需要重启 plasmashell 才会加载新 QML。
   注意：重启会重建所有小组件，只在内存里保存的开关会复位（例如电池小程序的
   “阻止睡眠/咖啡因”）。不想现在重启可以改用：bash install.sh --no-restart
TXT
    if systemctl --user restart plasma-plasmashell.service 2>/dev/null; then
        echo "   已重启 plasmashell"
    else
        echo "   重启失败，请手动执行: systemctl --user restart plasma-plasmashell"
    fi
fi

echo
cat <<'TXT'
完成。接下来：
  1) 编辑 /etc/kde-hotspot/config，把 SSID/PASS 改成你自己的
     （未设置时后端会拒绝启动热点，不会用默认密码）
  2) 把插件放进托盘：右键面板 → 系统托盘设置 → 条目 → 勾选“Wi-Fi 热点控制”
     或者直接把它拖到面板上（面板上会显示频段/信道文字）
  3) 也可以从应用菜单/KRunner 搜“Wi-Fi 热点控制”打开独立窗口
TXT
