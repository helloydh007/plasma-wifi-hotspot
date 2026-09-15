#!/bin/bash
# 重新生成翻译：QML → pot，po/*.po → 插件包 contents/locale/*/*.mo
# 依赖：gettext（xgettext / msgfmt）。改了 QML 里的 i18n 字符串后运行本脚本，
#       新字符串会出现在 pot 里待翻译；已翻译的 po 直接重编译。
#
# 翻译域：Plasma 的约定是 "plasma_applet_<插件ID>"（与系统自带小部件一致），
# 因此 .mo 文件名必须带 plasma_applet_ 前缀，否则 plasmashell 找不到目录。
set -e
cd "$(dirname "$0")"
DOMAIN=plasma_applet_org.kde.hotspot

xgettext --from-code=UTF-8 --language=JavaScript \
    --keyword=i18n --keyword=i18nc:1c,2 --keyword=i18np:1,2 --keyword=i18ncp:1c,2,3 \
    -F -o po/org.kde.hotspot.pot plasmoid/contents/ui/*.qml

for po in po/*.po; do
    lang=$(basename "$po" .po)
    dir="plasmoid/contents/locale/$lang/LC_MESSAGES"
    mkdir -p "$dir"
    msgfmt --check -o "$dir/$DOMAIN.mo" "$po"
    echo "  $lang -> $dir/$DOMAIN.mo"
done
echo "翻译已重新编译（之后记得 kpackagetool6 -u 并重启 plasmashell）"
