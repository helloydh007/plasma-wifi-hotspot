#!/bin/bash
# 把 backend/ 同步进插件包（插件内的“一键修复”会用到 plasmoid/contents/backend/deploy.sh）
# 改动 backend/ 后运行本脚本，再提交/安装，保证两处一致。
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"
DST="$SRC/plasmoid/contents/backend"
install -d -m 755 "$DST"
install -m 755 "$SRC/backend/kde-hotspot-ctl" "$SRC/backend/kde-hotspot.sh" "$SRC/backend/deploy.sh" "$DST/"
install -m 644 "$SRC"/backend/*.service "$SRC"/backend/*.policy "$SRC"/backend/*.rules \
               "$SRC"/backend/*.desktop "$SRC"/backend/*.conf "$SRC"/backend/config.example "$DST/"
echo "已同步 $(ls -1 "$DST" | wc -l) 个文件到 plasmoid/contents/backend/"
