#!/bin/bash
# 安装/更新：部署后端（root）+ 安装 Plasma 插件（用户级）+ 桌面入口 + 桌面快捷方式
#
# 用法：bash install.sh [--no-restart] [--no-desktop-shortcut]
#   --no-restart  即使插件内容有变化也不重启 plasmashell（注销重登后同样生效）
#   --restart     强制重启 plasmashell
#   --no-desktop-shortcut  不在桌面创建快捷方式（应用菜单入口照常安装）
#
# 关于 plasmashell 重启：plasmashell 会把插件 QML 读进内存，更新插件后必须重启
# （或注销重登）才会加载新界面。但重启会重建所有小组件，只在内存里保存的开关会
# 复位——例如电池小程序的“阻止睡眠/咖啡因”、第三方插件未持久化的状态。
# 因此这里只在**插件内容确实变化时**才重启：仅后端改动（脚本/单元/polkit）不会
# 触发重启。
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"
HASHFILE="$HOME/.local/share/kde-hotspot/plasmoid.hash"
# 界面指纹单独存一份：插件包内的后端副本（contents/backend）变化时必须重装包
# （否则插件里「一键修复」用的副本会停在旧版），但**不需要**重启 plasmashell。
UIHASHFILE="$HOME/.local/share/kde-hotspot/plasmoid.ui.hash"

RESTART=auto
DESKTOP_SHORTCUT=yes
for a in "$@"; do
    case "$a" in
        --no-restart) RESTART=no ;;
        --restart)    RESTART=yes ;;
        --no-desktop-shortcut) DESKTOP_SHORTCUT=no ;;
        -h|--help)    sed -n '3,6p' "$0"; exit 0 ;;
        *) echo "未知参数：$a（可用：--no-restart / --restart / --no-desktop-shortcut）" >&2; exit 2 ;;
    esac
done

# 插件包内容指纹：覆盖包里所有安装内容（含 contents/backend）。
# 决定要不要执行 kpackagetool6 重装。
plasmoid_hash(){
    ( cd "$SRC/plasmoid" && \
      find metadata.json contents -type f 2>/dev/null \
        | sort | xargs sha256sum | sha256sum | cut -d' ' -f1 )
}

# 界面指纹：只对"会影响已加载界面"的文件取指纹（QML/元数据/配置模式/翻译）。
# 决定要不要重启 plasmashell——只更新了包内后端副本时不该重启。
plasmoid_ui_hash(){
    ( cd "$SRC/plasmoid" && \
      find metadata.json contents/ui contents/config contents/locale -type f 2>/dev/null \
        | sort | xargs sha256sum | sha256sum | cut -d' ' -f1 )
}

echo "== 1) 部署后端（会弹一次授权框）=="
pkexec bash "$SRC/backend/deploy.sh"

echo
echo "== 2) 同步后端副本进插件包（供插件内的【一键修复】）=="
bash "$SRC/sync-backend.sh"

echo
echo "== 2b) 迁移旧命名空间（org.kde.hotspot → io.github.helloydh007.hotspot）=="
LEGACY_ID=org.kde.hotspot
NEW_ID=io.github.helloydh007.hotspot
if kpackagetool6 -t Plasma/Applet -l 2>/dev/null | grep -qx "$LEGACY_ID"; then
    APPSRC="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
    if [ -f "$APPSRC" ]; then
        cp -a "$APPSRC" "$APPSRC.bak-namespace-migration"
        # 托盘接线（extraItems/knownItems 等）里存的是插件 ID，必须一起改，
        # 否则更新后托盘里的小组件会变成失效条目
        sed -i "s/org\.kde\.hotspot/$NEW_ID/g" "$APPSRC"
        echo "   已更新托盘接线（原文件备份为 $(basename "$APPSRC").bak-namespace-migration）"
    fi
    kpackagetool6 -t Plasma/Applet -r "$LEGACY_ID" >/dev/null 2>&1 || true
    rm -rf "$HOME/.local/share/plasma/plasmoids/$LEGACY_ID"
    rm -f "$HOME/.local/share/applications/$LEGACY_ID.desktop"
    rm -f "$HOME/.local/share/locale/zh_CN/LC_MESSAGES/plasma_applet_$LEGACY_ID.mo"
    echo "   已卸载旧插件并清理旧桌面入口"
else
    echo "   无需迁移（未安装旧 ID）"
fi

echo
echo "== 3) 安装 Plasma 插件（用户级，无需 root）=="
NEW_HASH="$(plasmoid_hash)"
NEW_UI_HASH="$(plasmoid_ui_hash)"
OLD_HASH=""
[ -r "$HASHFILE" ] && OLD_HASH="$(cat "$HASHFILE" 2>/dev/null)"
OLD_UI_HASH=""
[ -r "$UIHASHFILE" ] && OLD_UI_HASH="$(cat "$UIHASHFILE" 2>/dev/null)"
NEED_RESTART=yes

if [ "$NEW_HASH" = "$OLD_HASH" ] && kpackagetool6 -t Plasma/Applet -l 2>/dev/null | grep -qx 'io.github.helloydh007.hotspot'; then
    echo "   插件内容与上次安装一致 → 跳过重装（界面无需刷新）"
    NEED_RESTART=no
else
    if kpackagetool6 -t Plasma/Applet -l 2>/dev/null | grep -qx 'io.github.helloydh007.hotspot'; then
        kpackagetool6 -t Plasma/Applet -u "$SRC/plasmoid"
    else
        kpackagetool6 -t Plasma/Applet -i "$SRC/plasmoid"
    fi
    mkdir -p "$(dirname "$HASHFILE")"
    printf '%s\n' "$NEW_HASH" > "$HASHFILE"
    printf '%s\n' "$NEW_UI_HASH" > "$UIHASHFILE"
    # 只更新了包内后端副本（界面指纹没变）→ 重装了包但不需要重启 plasmashell
    if [ "$NEW_UI_HASH" = "$OLD_UI_HASH" ]; then
        echo "   只更新了插件包内容（界面未变）→ 不重启 plasmashell"
        NEED_RESTART=no
    fi
fi

echo
echo "== 4) 安装桌面入口 =="
install -m 644 "$SRC/backend/io.github.helloydh007.hotspot.desktop" "$HOME/.local/share/applications/"
# 桌面快捷方式：默认在桌面创建一个图标（双击即可打开面板）。
# 桌面目录按 xdg-user-dir 解析（中文系统通常是 ~/桌面）；不想创建用 --no-desktop-shortcut。
if [ "$DESKTOP_SHORTCUT" = yes ]; then
    DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
    [ -n "$DESKTOP_DIR" ] || DESKTOP_DIR="$HOME/Desktop"
    if [ -d "$DESKTOP_DIR" ]; then
        install -m 644 "$SRC/backend/io.github.helloydh007.hotspot.desktop" \
            "$DESKTOP_DIR/io.github.helloydh007.hotspot.desktop"
        echo "   已创建桌面快捷方式：$DESKTOP_DIR/io.github.helloydh007.hotspot.desktop"
    else
        echo "   未找到桌面目录（$DESKTOP_DIR），跳过桌面快捷方式（应用菜单入口不受影响）"
    fi
else
    echo "   已按要求跳过桌面快捷方式"
fi
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
  1) 热点名称/密码：打开面板直接改（首次部署已自动生成随机密码，
     不会有“示例默认密码”这种问题；也可以编辑 /etc/kde-hotspot/config
     里的 SSID/PASS，然后 systemctl restart kde-hotspot 让它生效）
  2) 把插件放进托盘：右键面板 → 系统托盘设置 → 条目 → 勾选“Wi-Fi 热点控制”
     或者直接把它拖到面板上（面板上会显示频段/信道文字）
  3) 也可以从应用菜单/KRunner 搜“Wi-Fi 热点控制”打开独立窗口，
     或者双击桌面上的快捷方式（若已创建）
  4) 不想再用时：右键托盘图标 → “退出并关闭热点”，系统会退回默认状态
     （停热点、关开机自启、还原 Wi-Fi）；图标本身可在托盘设置里移除
TXT
