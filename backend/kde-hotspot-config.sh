#!/bin/bash
# kde-hotspot 配置文件库：纯数据 KEY=value 的解析 / 回写 / 凭据校验。
#
# 为什么不再 `. "$CONF"`（评审报告 §3.1 的 P0）：
#   SSID/密码来自用户输入。用 source 加载时 shell 会对这些值做词分割、变量展开与
#   命令替换——含空格/撇号/$ 的正常名字会静默损坏，而 `SSID=$(任意命令)` 更会在
#   root 服务加载配置时以 root 执行。因此这里把配置当纯数据逐行解析，值一律按
#   字面处理，全程不使用 eval/source。
#
# 格式（与 config.example 的说明一致）：
#   - 空行、以及首个非空白字符是 # 或 ; 的行是注释
#   - KEY=VALUE，键必须匹配 [A-Za-z_][A-Za-z0-9_]*；只认识白名单键，其余忽略
#   - 值两侧空白会被去掉；行尾 "空白 + # ..." 视为行尾注释
#   - 值以成对的 ' 或 " 整体包裹时为"带引号形式"，其中的 \' \" \\ 会被反转义
#     （本项目自有格式，不是 shell：配置文件是纯数据，不要 source 它）
#   - 写入时只有明显安全的字符才裸写，其余自动加单引号并转义；行尾注释会保留
#
# 本库被 root 的 kde-hotspot-ctl 与 kde-hotspot.sh 共用，加载时不得有副作用。
# 路径可用 KDE_HOTSPOT_CONF 覆盖（自定义安装位置/测试用）。

# 白名单：只有这些键会被加载成同名 shell 变量
HS_KEYS="STA_IF AP_IF AP_IP AP_NET SSID PASS MODE COUNTRY FALLBACK_2G RULE_PRIO NORMAL_CHANNEL DHCP_START DHCP_END DHCP_DNS"

hs_conf_path(){ printf '%s' "${KDE_HOTSPOT_CONF:-/etc/kde-hotspot/config}"; }

hs_key_known(){
    case " $HS_KEYS " in
        *" ${1:-} "*) return 0 ;;
    esac
    return 1
}

# ---------- 内部小工具（全部按字节处理，避免多字节/Locale 差异）----------
_hs_ltrim(){
    local s=${1:-}
    printf '%s' "${s#"${s%%[![:space:]]*}"}"
}
_hs_rtrim(){
    local s=${1:-}
    printf '%s' "${s%"${s##*[![:space:]]}"}"
}
_hs_has_ctrl(){
    local s=${1:-}
    local i=0 n c
    local LC_ALL=C
    n=${#s}
    while [ "$i" -lt "$n" ]; do
        c=${s:i:1}
        case "$c" in
            [[:cntrl:]]) return 0 ;;
        esac
        i=$((i + 1))
    done
    return 1
}
# 反转义：引号内的 \\ 与 \<引号> 还原成 \ 与引号本身，其余字符原样保留
_hs_unescape(){
    local s=${1:-}
    local q=${2:-}
    local i=0 n out=""
    local LC_ALL=C
    n=${#s}
    while [ "$i" -lt "$n" ]; do
        local c=${s:i:1}
        if [ "$c" = "\\" ] && [ $((i + 1)) -lt "$n" ]; then
            local nx=${s:i+1:1}
            if [ "$nx" = "\\" ] || [ "$nx" = "$q" ]; then
                out+=$nx
                i=$((i + 2))
                continue
            fi
        fi
        out+=$c
        i=$((i + 1))
    done
    printf '%s' "$out"
}
# 转义：\ -> \\ ，引号字符 -> \<引号>
_hs_escape(){
    local s=${1:-}
    local q=${2:-}
    s=${s//\\/\\\\}
    s=${s//$q/\\$q}
    printf '%s' "$s"
}
# 是否需要加引号：只有"明显安全"的字符才裸写，其余一律单引号包裹
_hs_needs_quote(){
    local v=${1:-}
    [ -z "$v" ] && return 1
    case "$v" in
        *[!A-Za-z0-9._:/@%+,-]*) return 0 ;;
    esac
    return 1
}
_hs_quote_value(){
    local v=${1:-}
    if _hs_needs_quote "$v"; then
        printf "'%s'" "$(_hs_escape "$v" "'")"
    else
        printf '%s' "$v"
    fi
}
# 位置 idx 之前连续反斜杠的数量（用于判断该引号是否被转义）
_hs_backslashes_before(){
    local s=${1:-}
    local idx=${2:-0}
    local LC_ALL=C
    local n=0
    local i=$((idx - 1))
    while [ "$i" -ge 0 ] && [ "${s:i:1}" = "\\" ]; do
        n=$((n + 1))
        i=$((i - 1))
    done
    printf '%s' "$n"
}

# ---------- 解析 ----------
# hs_conf_parse_line <行>：有效赋值时设置并返回 0：
#   HS_PARSE_KEY    键
#   HS_PARSE_VALUE  去掉引号与行尾注释后的字面值
#   HS_PARSE_SUFFIX 行尾注释原文（含前导空白；没有则为空），回写时保留
# 返回 1：空行 / 注释行 / 无 = / 键不合法
hs_conf_parse_line(){
    local line=$1 key val vs q body tail rest i c prev
    local LC_ALL=C
    HS_PARSE_KEY=""
    HS_PARSE_VALUE=""
    HS_PARSE_SUFFIX=""

    line=${line%$'\r'}
    line=$(_hs_ltrim "$line")
    case "$line" in
        ''|'#'*|';'*) return 1 ;;
    esac
    case "$line" in
        *=*) ;;
        *) return 1 ;;
    esac
    key=$(_hs_rtrim "${line%%=*}")
    case "$key" in
        ''|[0-9]*|*[!A-Za-z0-9_]*) return 1 ;;
    esac
    val=${line#*=}

    # 1) 整体被引号包裹：内部的 " # " 不是注释（写回时就是这个形式）
    vs=$(_hs_ltrim "$val")
    case "$vs" in
        \'*|\"*)
            q=${vs:0:1}
            body=${vs:1}
            tail=${body##*"$q"}
            if [ "${#tail}" -lt "${#body}" ]; then
                i=$(( ${#body} - ${#tail} - 1 ))          # body 中最后一个引号的下标
                local bs
                bs=$(_hs_backslashes_before "$body" "$i")
                if [ $(( bs % 2 )) -eq 0 ]; then
                    rest=$(_hs_rtrim "$tail")
                    case "$rest" in
                        ''|'#'*)
                            HS_PARSE_KEY=$key
                            HS_PARSE_VALUE=$(_hs_unescape "${body:0:$i}" "$q")
                            HS_PARSE_SUFFIX=$tail
                            return 0
                            ;;
                    esac
                fi
            fi
            ;;
    esac

    # 2) 裸值：去掉尾部空白与行尾注释
    val=$(_hs_rtrim "$(_hs_ltrim "$val")")
    i=0
    prev=""
    while [ "$i" -lt "${#val}" ]; do
        c=${val:i:1}
        if [ "$c" = '#' ] && [ "$i" -gt 0 ]; then
            case "$prev" in
                ' '|$'\t'|$'\v'|$'\f')
                    HS_PARSE_KEY=$key
                    HS_PARSE_VALUE=$(_hs_rtrim "${val:0:$i}")
                    HS_PARSE_SUFFIX=${val:$((i - 1))}
                    return 0
                    ;;
            esac
        fi
        prev=$c
        i=$((i + 1))
    done
    HS_PARSE_KEY=$key
    HS_PARSE_VALUE=$val
    return 0
}

# hs_conf_get <键>：打印值；键不存在返回 1
# 同一键出现多次时取**最后一次**：与旧实现 `. config`（shell source）的行为一致，
# 也与 hs_conf_load 保持一致（否则面板显示的值和实际生效的值会不一样）。
hs_conf_get(){
    local want=$1 f line out found=no
    f=$(hs_conf_path)
    [ -r "$f" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        hs_conf_parse_line "$line" || continue
        [ "$HS_PARSE_KEY" = "$want" ] || continue
        out=$HS_PARSE_VALUE
        found=yes
    done < "$f"
    [ "$found" = yes ] || return 1
    printf '%s\n' "$out"
}

# hs_conf_load：把白名单键加载成同名变量（等价于旧 `. config`，但不会执行内容）
# 可选键的默认值：配置里**没写或写成空**时由库统一补上。
#
# 为什么放在库里而不是各调用方：2026-09-16 的实机故障就是"调用方自己补默认值"补漏了——
# kde-hotspot.sh 在 hs_conf_load **之前**设了 RULE_PRIO=${RULE_PRIO:-8990}，而 load 会先把
# 白名单键全部 unset 再只装文件里有的键，于是默认值被自己清掉，后面 "$RULE_PRIO" 在
# `set -u` 下直接让脚本退出（87ms、exit 1）。默认值集中在库里，"键没写"就永远不会是坑。
HS_KEY_DEFAULTS="AP_IF=ap0 AP_IP=10.233.33.1 MODE=concurrent FALLBACK_2G=yes RULE_PRIO=8990 NORMAL_CHANNEL=6 DHCP_START=50 DHCP_END=150 DHCP_DNS=223.5.5.5,119.29.29.29"

# 给"没写或写成空"的白名单键补默认值。必须在 hs_conf_load 之后调用。
hs_conf_apply_defaults(){
    local kv k v
    for kv in $HS_KEY_DEFAULTS; do
        k=${kv%%=*}
        v=${kv#*=}
        [ -n "${!k:-}" ] || printf -v "$k" '%s' "$v"
    done
}

# 先清空白名单键：配置是唯一数据源，残留的环境变量不能冒充配置（root 场景下的边界）
HS_CONF_READABLE=no
hs_conf_reset(){
    local k
    for k in $HS_KEYS; do unset "$k" 2>/dev/null || true; done
}
hs_conf_load(){
    local f line k
    HS_CONF_READABLE=no
    hs_conf_reset
    f=$(hs_conf_path)
    if [ ! -r "$f" ]; then
        hs_conf_apply_defaults      # 读不到也要给一套安全默认值
        return 1
    fi
    # shellcheck disable=SC2034  # 由调用方（kde-hotspot-ctl）读取
    HS_CONF_READABLE=yes
    while IFS= read -r line || [ -n "$line" ]; do
        hs_conf_parse_line "$line" || continue
        k=$HS_PARSE_KEY
        hs_key_known "$k" || continue
        printf -v "$k" '%s' "$HS_PARSE_VALUE"
    done < "$f"
    hs_conf_apply_defaults
    return 0
}

# hs_derive_ap_net <AP_IP>：由 AP_IP 推导热点网段（网关/DHCP 池/iptables 全部以它为准，
# 避免 AP_IP 与 AP_NET 各写一份导致 "网关在 A 网段、NAT 规则写在 B 网段"）。
# 只支持 /24：DHCP 池按最后一段生成。非法输入返回 1。
hs_derive_ap_net(){
    local ip=${1:-}
    case "$ip" in
        [0-9]*.[0-9]*.[0-9]*.[0-9]*) ;;
        *) return 1 ;;
    esac
    case "$ip" in
        *[!0-9.]*) return 1 ;;
    esac
    printf '%s.0/24\n' "${ip%.*}"
}

# ---------- 运行时标记 ----------
# hs_boot_epoch：本次开机的时间点（现在 - uptime）。取不到返回 1。
hs_boot_epoch(){
    local up now
    up=$(cut -d. -f1 /proc/uptime 2>/dev/null) || return 1
    case "$up" in ''|*[!0-9]*) return 1 ;; esac
    now=$(date +%s 2>/dev/null) || return 1
    case "$now" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$((now - up))"
}

# hs_marker_is_current <文件>：标记存在，且是**本次开机之后**写的。
# 用途：像"保持关闭"这类运行时标记只在本次开机内生效——否则用户同时开了
# "开机自启"，重启后热点反而起不来（关热点不该动开机自启）。
# 取不到开机时间时按"有效"处理（保守：宁可先不启动，也不要偷偷起热点）。
hs_marker_is_current(){
    local f=${1:-} mt boot
    [ -n "$f" ] && [ -e "$f" ] || return 1
    mt=$(stat -c %Y "$f" 2>/dev/null) || return 1
    boot=$(hs_boot_epoch) || return 0
    [ "$mt" -ge "$boot" ]
}

# hs_conf_set <键> <值> [<键> <值> ...]：就地重写（原子替换）
#   - 其它行原样保留；被改的行保留其行尾注释
#   - 键不在白名单、值含换行/回车 → 返回 1（不写坏文件）
hs_conf_set(){
    local -a keys=() vals=()
    local k v
    while [ "$#" -gt 0 ]; do
        k=${1:-}
        v=${2:-}
        case "$k" in
            ''|[0-9]*|*[!A-Za-z0-9_]*) return 1 ;;
        esac
        hs_key_known "$k" || return 1
        case "$v" in
            *$'\n'*|*$'\r'*) return 1 ;;
        esac
        keys+=("$k")
        vals+=("$v")
        [ "$#" -ge 2 ] || return 1
        shift 2
    done
    [ "${#keys[@]}" -gt 0 ] || return 1

    local f tmp line
    f=$(hs_conf_path)
    tmp=$(mktemp "${f}.XXXXXX" 2>/dev/null) || return 1
    chmod 600 "$tmp" 2>/dev/null || true

    local -a seen=()
    local i found
    if [ -r "$f" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            found=-1
            if hs_conf_parse_line "$line" && [ -n "$HS_PARSE_KEY" ]; then
                for i in "${!keys[@]}"; do
                    if [ "${keys[$i]}" = "$HS_PARSE_KEY" ]; then found=$i; break; fi
                done
            fi
            if [ "$found" -ge 0 ]; then
                # 同一键出现多次时只保留第一次：不留下会被读到的旧值（否则"文件里有两个值"）
                if [ "${seen[$found]:-}" = "1" ]; then
                    continue
                fi
                printf '%s=%s%s\n' "${keys[$found]}" \
                    "$(_hs_quote_value "${vals[$found]}")" "$HS_PARSE_SUFFIX" >> "$tmp"
                seen[found]=1
            else
                printf '%s\n' "$line" >> "$tmp"
            fi
        done < "$f"
    fi
    for i in "${!keys[@]}"; do
        [ "${seen[$i]:-}" = "1" ] && continue
        printf '%s=%s\n' "${keys[$i]}" "$(_hs_quote_value "${vals[$i]}")" >> "$tmp"
    done

    if [ "$(id -u 2>/dev/null)" = "0" ]; then
        # root：保持 root 属主与原属组（配置含密码，权限由 ctl 的 fix_conf_perm 兜底）
        local grp=""
        grp=$(stat -c %G "$f" 2>/dev/null)
        [ -n "$grp" ] || grp=root
        install -m 640 -o root -g "$grp" "$tmp" "$f" 2>/dev/null || cat "$tmp" > "$f"
    else
        cat "$tmp" > "$f"      # 非 root（自定义位置/测试）：保留原文件权限
    fi
    rm -f "$tmp"
    return 0
}

# ---------- 凭据校验（ctl 与监督脚本共用，避免两份实现漂移）----------
# hs_cred_problem [SSID] [PASS]：打印所有问题（第一行即原因）；有问题返回 0
hs_cred_problem(){
    local s=${1-${SSID:-}}
    local p=${2-${PASS:-}}
    local bad=0
    if [ -z "$s" ]; then
        echo "热点名称未设置"; bad=1
    elif _hs_has_ctrl "$s"; then
        echo "热点名称含控制字符"; bad=1
    elif [ "${#s}" -gt 32 ]; then
        echo "热点名称最长 32 个字符"; bad=1
    else
        case "$s" in
            my-hotspot|your-ssid*|change-me*|changeme*|example*)
                echo "热点名称仍是示例占位值（$s）"; bad=1 ;;
        esac
    fi
    if [ -z "$p" ]; then
        echo "热点密码未设置"; bad=1
    elif _hs_has_ctrl "$p"; then
        echo "热点密码含控制字符"; bad=1
    elif [ "${#p}" -lt 8 ] || [ "${#p}" -gt 63 ]; then
        echo "热点密码长度需 8-63 位"; bad=1
    else
        case "$p" in
            change-me*|changeme*|your-password*|example*)
                echo "热点密码仍是示例占位值"; bad=1 ;;
        esac
    fi
    [ "$bad" = 1 ]
}
hs_cred_ok(){ ! hs_cred_problem "$@"; }
