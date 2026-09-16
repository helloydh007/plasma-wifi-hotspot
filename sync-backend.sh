#!/bin/bash
# 把 backend/ 同步进插件包（插件内的【一键修复】会用到 plasmoid/contents/backend/deploy.sh）
# 改动 backend/ 后运行本脚本，再提交/安装，保证两处一致。
#
#   bash sync-backend.sh          复制 backend/ → plasmoid/contents/backend/
#   bash sync-backend.sh --check  只比较两处是否一致（CI / 提交前自检用，不一致退出 1）
#
# 为什么保留两份：从 KDE Store 安装时只有插件包（plasmoid/），没有仓库里的 backend/，
# 插件内的“一键修复”必须能用包内那份 deploy.sh 把后端装回来。因此需要同步 + 校验。
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"
DST="$SRC/plasmoid/contents/backend"
# 可执行文件（需要 +x）；其它文件一律按数据文件 644 同步。
# 这里用“显式列可执行文件 + 其余全部”的策略：曾经用 *.sh 之类的通配符漏掉了
# kde-hotspot-config.sh（配置库），包内 deploy.sh 会因此找不到它而失败。
EXEC_FILES="kde-hotspot-ctl kde-hotspot.sh deploy.sh"

sync_list() {
    local f b
    for b in $EXEC_FILES; do printf '%s\n' "$b"; done
    for f in "$SRC"/backend/*; do
        [ -f "$f" ] || continue
        b=$(basename "$f")
        case "$b" in
            *.md) continue ;;
        esac
        case " $EXEC_FILES " in
            *" $b "*) continue ;;
        esac
        printf '%s\n' "$b"
    done
}

LIST=$(sync_list)
NL=$'\n'

if [ "${1:-}" = "--check" ]; then
    rc=0
    while IFS= read -r b; do
        [ -n "$b" ] || continue
        if [ ! -e "$DST/$b" ]; then
            echo "缺少: plasmoid/contents/backend/$b（运行 bash sync-backend.sh）"
            rc=1
        elif ! cmp -s "$SRC/backend/$b" "$DST/$b"; then
            echo "不一致: backend/$b 与 plasmoid/contents/backend/$b（运行 bash sync-backend.sh）"
            rc=1
        fi
    done <<< "$LIST"
    for f in "$DST"/*; do
        [ -f "$f" ] || continue
        b=$(basename "$f")
        case "$NL$LIST$NL" in
            *"$NL$b$NL"*) ;;
            *) echo "多余: plasmoid/contents/backend/$b"; rc=1 ;;
        esac
    done
    if [ "$rc" -eq 0 ]; then
        echo "backend 与插件包内副本一致"
    fi
    exit "$rc"
fi

install -d -m 755 "$DST"
while IFS= read -r b; do
    [ -n "$b" ] || continue
    case " $EXEC_FILES " in
        *" $b "*) install -m 755 "$SRC/backend/$b" "$DST/$b" ;;
        *)        install -m 644 "$SRC/backend/$b" "$DST/$b" ;;
    esac
done <<< "$LIST"
echo "已同步 $(find "$DST" -maxdepth 1 -type f | wc -l) 个文件到 plasmoid/contents/backend/"
