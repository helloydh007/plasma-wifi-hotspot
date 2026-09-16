#!/bin/bash
# kde-hotspot-ctl 端到端行为测试（全 mock：不需要 root、不碰真实网络/服务）
#
# 做法：把 ctl 顶部那几行「绝对路径声明」sed 成本测试用的 mock 与临时目录，然后按命令跑，
#      断言三件事：① stdout 的 JSON 结果 ② 状态/配置文件的变化 ③ mock 记录下来的系统调用。
#
# 这样能在没有 root、没有 Plasma、没有网卡的环境里验证：
#   * 配置注入（旧版 `. config` 会执行 $(...)）不再发生
#   * status JSON 对引号/反斜杠/控制字符的转义合法
#   * off/autostart/mode 三者的语义对称（保持关闭 + 关闭自启 + 三个单元一起 disable）
#   * --pass-file 只接受「调用者自己的私有目录里的 600 普通文件」
#   * 改凭据会重启「待命中」的并发服务
#   * 按 rules.state 记录拆旧规则（STA_IF/AP_NET 改过也能清干净）
#   * DHCP 单元没起来时 on 明确失败（不再静默显示「运行中」）
#
# 用法：bash tests/test-ctl.sh
#
# 红-绿自检（证明这些断言确实能发现问题，而不是恒真）：
#   git show HEAD:backend/kde-hotspot-ctl > /tmp/old-ctl
#   CTL_SRC=/tmp/old-ctl bash tests/test-ctl.sh     # 修复前：63 通过 / 45 失败
# 修复前的实现里，配置里的 $(command) 会被执行（A 段会看到 CANARY 文件被创建）、
# $$ 被展开成进程号、status 的 JSON 遇到控制字符会直接非法。
#
# 本测试必须原样包含 $ / $(...) / $$ 等字面量（那正是被测对象）；
# ok/no 形式的 A && B || C 也是刻意写法。
# shellcheck disable=SC2016,SC2015
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
# 被测脚本来源：默认用仓库里的实现；设 CTL_SRC=... 可以指向别的版本，
# 用来做"红-绿"验证（例如指向 git HEAD 里的旧实现，确认这些断言真的会失败）。
CTL_SRC="${CTL_SRC:-$REPO/backend/kde-hotspot-ctl}"
WORK=$(mktemp -d)
BIN="$WORK/bin"
STATE="$WORK/state"
RUN="$WORK/run"
MOCKLOG="$WORK/mock.log"
MOCKSTATE="$WORK/mockstate"
CONF="$WORK/config"
CTL="$WORK/kde-hotspot-ctl"
OUTFILE="$WORK/out.json"
ARP_FIXTURE="$WORK/arp"
DNSMASQ_FIXTURE="$WORK/dnsmasq.conf"
LIB="$REPO/backend/kde-hotspot-config.sh"
cleanup_all(){ rm -rf "$WORK"; }
trap cleanup_all EXIT

# mock 脚本是子进程，必须靠环境变量拿到日志/状态路径
export MOCKLOG MOCKSTATE
export MOCK_STA_IF=wlan0

T_PASS=0; T_FAIL=0
ok(){ T_PASS=$((T_PASS + 1)); printf '  ok   %s\n' "$1"; }
no(){ T_FAIL=$((T_FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
is(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "期望 [$3] 实际 [$2]"; fi; }
contains(){ case "$2" in *"$3"*) ok "$1" ;; *) no "$1" "[$2] 中不含 [$3]" ;; esac; }
not_contains(){ case "$2" in *"$3"*) no "$1" "[$2] 中不应含 [$3]" ;; *) ok "$1" ;; esac; }
section(){ printf '\n== %s ==\n' "$1"; }

# ---------- mock 工具 ----------
write_mocks(){
    mkdir -p "$BIN"

    cat > "$BIN/systemctl" <<'EOF'
#!/bin/bash
printf 'systemctl %s\n' "$*" >> "$MOCKLOG"
S=$MOCKSTATE
case "${1:-}" in
  is-active)
     # 真实 systemd：单元处于"崩溃后自动重启中"(activating/auto-restart) 时
     # is-active 也返回 0 —— 这正是"服务其实没起来、面板却报成功"的根源
     shift; [ "${1:-}" = "--quiet" ] && shift
     for u in "$@"; do
         if [ -e "$S/unitstate.$u" ]; then
             case "$(cut -d: -f1 < "$S/unitstate.$u")" in
                 activating|active) continue ;;
                 *) exit 3 ;;
             esac
         fi
         [ -e "$S/active.$u" ] || exit 3
     done
     exit 0 ;;
  is-enabled)
     shift; [ "${1:-}" = "--quiet" ] && shift
     for u in "$@"; do [ -e "$S/enabled.$u" ] || exit 1; done
     exit 0 ;;
  show)
     # systemctl show -p ActiveState -p SubState --value U1 U2...
     shift
     props=""
     while [ "$#" -gt 0 ]; do
         case "$1" in
             -p) shift; props="$props ${1:-}" ;;
             --value|-*) ;;
             *) break ;;
         esac
         shift
     done
     first=1
     for u in "$@"; do
         # 真实 systemd 在多个单元之间会多输出一个空行，这里必须一致地模拟，
         # 否则"按行号 read"的解析在真机上错位、在 mock 里却看不出来
         [ "$first" = 1 ] || echo ""
         first=0
         ast=inactive; sub=dead
         if [ -e "$S/unitstate.$u" ]; then
             IFS=: read -r ast sub < "$S/unitstate.$u"
         elif [ -e "$S/active.$u" ]; then
             ast=active; sub=running
         fi
         for pr in $props; do
             case "$pr" in
                 ActiveState) echo "$ast" ;;
                 SubState) echo "$sub" ;;
                 *) echo "" ;;
             esac
         done
     done
     exit 0 ;;
  start|restart)
     shift
     for u in "$@"; do [ -e "$S/failstart.$u" ] || : > "$S/active.$u"; done ;;
  stop) shift; for u in "$@"; do rm -f "$S/active.$u"; done ;;
  enable) shift; for u in "$@"; do : > "$S/enabled.$u"; done ;;
  disable) shift; for u in "$@"; do rm -f "$S/enabled.$u"; done ;;
esac
exit 0
EOF

    cat > "$BIN/ip" <<'EOF'
#!/bin/bash
printf 'ip %s\n' "$*" >> "$MOCKLOG"
exit 0
EOF

    cat > "$BIN/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF

    cat > "$BIN/iptables" <<'EOF'
#!/bin/bash
printf 'iptables %s\n' "$*" >> "$MOCKLOG"
S=$MOCKSTATE
# 归一化：去掉动作词与 -I 的插入位置，使 -C / -I / -A / -D 能比对同一条规则。
# 注意把参数串用空格包起来，否则"以动作词开头"的调用（iptables -C FORWARD ...）匹配不到，
# 会一路落到最后的 exit 0，表现为"-C 永远说规则存在" → 重复插入的 bug 就测不出来。
args=" $* "
norm=$(printf '%s' "$args" | sed -E 's/ -(C|I|A|D) / /; s/ (FORWARD|INPUT|OUTPUT|PREROUTING|POSTROUTING) [0-9]+ / \1 /')
rule=${norm# }
rule=${rule% }
case "$args" in
  *" -C "*) grep -qxF -- "$rule" "$S/ipt.rules" 2>/dev/null && exit 0 || exit 1 ;;
  *" -I "*|*" -A "*)
      grep -qxF -- "$rule" "$S/ipt.rules" 2>/dev/null || printf '%s\n' "$rule" >> "$S/ipt.rules"
      exit 0 ;;
  *" -D "*)
      grep -vxF -- "$rule" "$S/ipt.rules" > "$S/ipt.tmp" 2>/dev/null || true
      mv -f "$S/ipt.tmp" "$S/ipt.rules" 2>/dev/null || true
      exit 0 ;;
esac
exit 0
EOF

    cat > "$BIN/iw" <<'EOF'
#!/bin/bash
printf 'iw %s\n' "$*" >> "$MOCKLOG"
S=$MOCKSTATE
case "${1:-}" in
  dev)
    if [ -z "${2:-}" ]; then
        printf 'phy#0\n'
        printf '\tInterface %s\n' "${MOCK_STA_IF:-wlan0}"
        printf '\t\ttype managed\n'
        [ -n "$(cat "$S/sta.channel" 2>/dev/null)" ] && \
            printf '\t\tchannel %s (2437 MHz), width: 20 MHz\n' "$(cat "$S/sta.channel")"
        printf '\t\tssid %s\n' "$(cat "$S/sta.ssid" 2>/dev/null)"
        if [ -e "$S/ap.exists" ]; then
            printf '\tInterface ap0\n\t\ttype AP\n'
            [ -n "$(cat "$S/ap.channel" 2>/dev/null)" ] && \
                printf '\t\tchannel %s (5180 MHz), width: 20 MHz\n' "$(cat "$S/ap.channel")"
        fi
        exit 0
    fi
    case "${3:-}" in
      info)
        [ -e "$S/missing.$2" ] && exit 1
        printf 'Interface %s\n\twiphy 0\n' "$2"; exit 0 ;;
      link)
        printf 'Connected to aa:bb:cc:dd:ee:ff (on %s)\n' "$2"
        printf '\tSSID: %s\n' "$(cat "$S/sta.ssid" 2>/dev/null)"
        printf '\tfreq: %s\n' "$(cat "$S/sta.freq" 2>/dev/null)"
        exit 0 ;;
      station) exit 0 ;;
    esac
    exit 0 ;;
  phy) exit 0 ;;
  reg) printf 'country %s: DFS-ETSI\n' "${MOCK_COUNTRY:-DE}"; exit 0 ;;
esac
exit 0
EOF

    cat > "$BIN/nmcli" <<'EOF'
#!/bin/bash
printf 'nmcli %s\n' "$*" >> "$MOCKLOG"
S=$MOCKSTATE
fields=""
getmode=no
while [ "$#" -gt 0 ]; do
    case "$1" in
        -t|--terse|-s|--show-secrets) ;;
        -f|--fields) shift; fields=${1:-} ;;
        -g|--get-values) shift; fields=${1:-}; getmode=yes ;;
        *) break ;;
    esac
    shift
done
cmd="$*"
ACTIVE_ONLY=no
case "$cmd" in
    *"connection show --active"*) ACTIVE_ONLY=yes ;;
esac

emit_conns(){
    while IFS='|' read -r uuid name type dev act; do
        [ -n "${uuid:-}" ] || continue
        [ "$ACTIVE_ONLY" = yes ] && [ "$act" != "yes" ] && continue
        local out="" f v
        for f in ${fields//,/ }; do
            case "$f" in
                UUID) v=$uuid ;; NAME) v=$name ;; TYPE) v=$type ;;
                DEVICE) v=$dev ;; STATE) v=$act ;; *) v=$name ;;
            esac
            out="${out:+$out:}$v"
        done
        printf '%s\n' "$out"
    done < "$S/nm.conns"
}

case "$cmd" in
    "device status"*)
        cat "$S/nm.devices" 2>/dev/null; exit 0 ;;
esac
# 测试开关：$MOCKSTATE/fail-band 存在时，改频段偏好返回失败（用于验证备份不被误删）
case "$cmd" in
    *"802-11-wireless.band"*)
        [ -e "$S/fail-band" ] && exit 1
        exit 0 ;;
esac
case "$cmd" in
    "connection show"|"connection show "*)
        case "$cmd" in
            "connection show --active"*) emit_conns; exit 0 ;;
            "connection show")
                emit_conns; exit 0 ;;
        esac
        target=${cmd#connection show }
        target=${target%% *}
        [ "$target" = "--active" ] && { emit_conns; exit 0; }
        if [ "$getmode" = yes ]; then
            key=${fields##*.}
            cat "$S/nm.$key" 2>/dev/null
            exit 0
        fi
        emit_conns | awk -F: -v t="$target" '$1==t || $2==t {print; exit}'
        exit 0 ;;
esac
exit 0
EOF
    chmod +x "$BIN"/*
}

# ---------- 把绝对路径声明改成测试环境 ----------
patch_ctl(){
    sed -e "s|^CONF=.*|CONF=$CONF|" \
        -e "s|^CONF_LIB=.*|CONF_LIB=$LIB|" \
        -e "s|^STATE=.*|STATE=$STATE|" \
        -e "s|^RUN=.*|RUN=$RUN|" \
        -e "s|^IW=.*|IW=$BIN/iw|" \
        -e "s|^NMCLI=.*|NMCLI=$BIN/nmcli|" \
        -e "s|^IPT=.*|IPT=$BIN/iptables|" \
        -e "s|^ARP=.*|ARP=$ARP_FIXTURE|" \
        -e "s|^DNSMASQ_CONF=.*|DNSMASQ_CONF=$DNSMASQ_FIXTURE|" \
        "$CTL_SRC" > "$CTL"
    chmod +x "$CTL"
    grep -q "^STATE=$STATE$" "$CTL" || { echo "补丁失败：STATE 未替换"; exit 1; }
    # 关键声明行不能还指向真实路径，否则测的就不是 mock 版本
    # （只看赋值行：脚本里的注释/提示语提到 /etc/kde-hotspot/config 是正常的）
    if grep -nE '^(STATE|RUN|IW|NMCLI|IPT|ARP|CONF|CONF_LIB)=' "$CTL" | grep -qE '=/etc/|=/var/|=/run/|=/usr/'; then
        echo "补丁失败：声明行仍指向真实路径"
        grep -nE '^(STATE|RUN|IW|NMCLI|IPT|ARP|CONF|CONF_LIB)=' "$CTL"
        exit 1
    fi
}

# ---------- 配置读写（一律走配置库，避免造出重复键）----------
cfg_set(){
    KDE_HOTSPOT_CONF="$CONF" bash -c '. "$1"; shift; hs_conf_set "$@"' _ "$LIB" "$@"
    chmod 600 "$CONF"
}
cfg_get(){
    KDE_HOTSPOT_CONF="$CONF" bash -c '. "$1"; hs_conf_get "$2"' _ "$LIB" "$1"
}

# ---------- 环境重置 ----------
reset(){
    rm -rf "$STATE" "$RUN" "$MOCKSTATE"
    mkdir -p "$STATE" "$RUN" "$MOCKSTATE"
    : > "$MOCKLOG"
    : > "$CONF"
    printf '6\n' > "$MOCKSTATE/sta.channel"          # STA 在 2.4G ch6
    printf '2437\n' > "$MOCKSTATE/sta.freq"
    printf 'MyWiFi\n' > "$MOCKSTATE/sta.ssid"
    printf 'wlan0:wifi:connected\n' > "$MOCKSTATE/nm.devices"
    cat > "$MOCKSTATE/nm.conns" <<'EOD'
uuid-home|HomeWifi|802-11-wireless|wlan0|yes
uuid-eth0|Wired|802-3-ethernet|eth0|yes
EOD
    : > "$ARP_FIXTURE"
    : > "$MOCKSTATE/ipt.rules"
    : > "$WORK/out.txt"
    cfg_set SSID MyNet PASS secret-pass-123 MODE concurrent STA_IF wlan0 AP_IP 10.233.33.1
}

# ---------- 运行 ----------
PKEXEC_UID_OVERRIDE=""
run(){
    PATH="$BIN:$PATH" KDE_HOTSPOT_CONF="$CONF" \
    PKEXEC_UID="${PKEXEC_UID_OVERRIDE:-$(id -u)}" \
        "$CTL" "$@" > "$WORK/out.txt" 2> "$WORK/err.txt"
    RC=$?
    tail -1 "$WORK/out.txt" > "$OUTFILE"
}
run_status(){
    run status
    cp "$WORK/out.txt" "$OUTFILE"
}
jget(){ python3 -c '
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    for k in sys.argv[2].split("."):
        d = d[int(k)] if k.isdigit() else d[k]
    print("true" if d is True else "false" if d is False else d)
except Exception:
    print("<no-json>")
' "$OUTFILE" "$1"; }
json_parseable(){ python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$OUTFILE" >/dev/null 2>&1; }
mock_has(){ grep -qF -- "$1" "$MOCKLOG"; }

setup(){ write_mocks; patch_ctl; }

# ==========================================================================
setup

section "A. 配置注入（旧版 . config 会执行 \$(...)）"
reset
printf 'SSID=My$$Net\nPASS=$(touch %s/CANARY)\nMODE=concurrent\n' "$WORK" > "$CONF"
run_status
json_parseable && ok "status 输出是合法 JSON" || no "status 输出是合法 JSON" "$(head -3 "$WORK/err.txt")"
is "status 正常返回" "$RC" "0"
is "注入内容未被求值（没有 CANARY 文件）" "$([ -e "$WORK/CANARY" ] && echo yes || echo no)" "no"
is "PASS 按字面读取" "$(jget hotspot.pass)" '$(touch '"$WORK"'/CANARY)'
is "SSID 里的 \$\$ 按字面读取" "$(jget hotspot.ssid)" 'My$$Net'

section "B. status JSON 转义（引号/反斜杠/制表符/控制字符）"
reset
printf 'SSID=My"Net\\x\nPASS=abc\tdef\nMODE=concurrent\n' > "$CONF"
run_status
json_parseable && ok "带引号/反斜杠/制表符的 SSID 仍是合法 JSON" || no "带引号/反斜杠/制表符的 SSID 仍是合法 JSON"
is "SSID 往返一致" "$(jget hotspot.ssid)" 'My"Net\x'
is "PASS 里的制表符转成 \\t" "$(jget hotspot.pass)" "$(printf 'abc\tdef')"
reset
printf 'SSID=Bell\001Char\nPASS=secret-pass-123\n' > "$CONF"
run_status
json_parseable && ok "控制字符(0x01)不会破坏 JSON" || no "控制字符(0x01)不会破坏 JSON"
is "控制字符转成 \\u0001" "$(jget hotspot.ssid)" "$(printf 'Bell\001Char')"

section "C. status 字段与客户端计数"
reset
printf '9\n' > "$STATE/clients"
printf '36\n' > "$MOCKSTATE/ap.channel"
: > "$MOCKSTATE/ap.exists"
: > "$MOCKSTATE/active.kde-hotspot.service"
: > "$MOCKSTATE/active.kde-hotspot-dhcp.service"
cat > "$ARP_FIXTURE" <<'EOD'
IP address       HW type     Flags       HW address            Mask     Device
10.233.33.100    0x1         0x2         aa:bb:cc:dd:ee:01     *        ap0
10.233.33.101    0x1         0x0         aa:bb:cc:dd:ee:02     *        ap0
EOD
run_status
is "热点运行中" "$(jget hotspot.running)" "yes"
is "机制是 hostapd" "$(jget hotspot.mechanism)" "hostapd"
is "信道取自 ap0" "$(jget hotspot.channel)" "36"
is "频段 5G" "$(jget hotspot.band)" "5G"
is "网关是 AP_IP" "$(jget hotspot.gateway)" "10.233.33.1"
is "客户端数用监督脚本写的快照" "$(jget hotspot.clients)" "9"
is "DHCP 在跑" "$(jget hotspot.dhcp_active)" "yes"
is "多单元解析：systemd 的空行不会让 DHCP 状态错位" "$(jget hotspot.dhcp_active)" "yes"
is "多单元解析：normal 单元状态也不会错位" "$(jget normal_service_state)" "inactive/dead"
is "Wi-Fi 已连接" "$(jget wifi.connected)" "yes"
is "Wi-Fi 频段来自信道" "$(jget wifi.band)" "2.4G"
rm -f "$STATE/clients"
run_status
is "无快照时用 ARP 计数（只算 0x2）" "$(jget hotspot.clients)" "1"
# 普通模式 + AP profile 激活：机制是 nm，客户端走 STA_IF 的 ARP
reset
cfg_set MODE normal
cat > "$ARP_FIXTURE" <<'EOD'
IP address       HW type     Flags       HW address            Mask     Device
10.233.33.7      0x1         0x2         aa:bb:cc:dd:ee:07     *        wlan0
EOD
printf 'uuid-ap|kde-hotspot-normal|802-11-wireless|wlan0|yes\n' >> "$MOCKSTATE/nm.conns"
: > "$MOCKSTATE/ap.exists"
printf '6\n' > "$MOCKSTATE/ap.channel"
run_status
is "普通模式机制是 nm" "$(jget hotspot.mechanism)" "nm"
is "普通模式客户端数走 STA_IF 的 ARP" "$(jget hotspot.clients)" "1"
is "普通模式不报 DHCP 单元状态（dnsmasq 由 NM 托管）" "$(jget hotspot.dhcp_active)" "no"

section "D. STA_IF 自动探测（多网卡优先取已连接的）"
reset
cfg_set STA_IF wlanX
: > "$MOCKSTATE/missing.wlanX"
printf 'wlan9:wifi:connected\n' > "$MOCKSTATE/nm.devices"
run_status
is "改用 NM 里已连接的 Wi-Fi 设备" "$(jget wifi.iface)" "wlan9"
is "标记为自动探测" "$(jget sta_if_auto)" "true"

section "E. 关闭热点 = 只停当前，绝不动「开机自启」"
reset
: > "$STATE/autostart-normal"
: > "$MOCKSTATE/enabled.kde-hotspot.service"
: > "$MOCKSTATE/enabled.kde-hotspot-dhcp.service"
: > "$MOCKSTATE/enabled.kde-hotspot-normal.service"
: > "$MOCKSTATE/ap.exists"
printf '6\n' > "$MOCKSTATE/ap.channel"
: > "$MOCKSTATE/active.kde-hotspot.service"
rm -f "$MOCKSTATE/sta.channel"
run off
is "off 成功" "$(jget ok)" "true"
is "写了「保持关闭」标记（仅本次开机内有效）" "$([ -e "$STATE/disabled" ] && echo yes || echo no)" "yes"
is "不再 disable 任何单元（开机自启原样保留）" "$(grep -c 'systemctl disable' "$MOCKLOG" 2>/dev/null || true)" "0"
is "普通模式自启标记也不动" "$([ -e "$STATE/autostart-normal" ] && echo yes || echo no)" "yes"
mock_has "systemctl stop kde-hotspot.service kde-hotspot-dhcp.service" \
    && ok "停掉并发模式服务" || no "停掉并发模式服务"
mock_has "ip link set ap0 down" && ok "把 ap0 放倒" || no "把 ap0 放倒"
not_contains "提示文案不再说自启被关闭" "$(jget message)" "自启已关闭"

section "E2. 普通模式下关闭热点：同样不动开机自启"
reset
cfg_set MODE normal
: > "$STATE/autostart-normal"
printf 'uuid-ap|kde-hotspot-normal|802-11-wireless|wlan0|yes\n' >> "$MOCKSTATE/nm.conns"
: > "$MOCKLOG"
run off
is "off 成功" "$(jget ok)" "true"
is "普通模式自启标记保留" "$([ -e "$STATE/autostart-normal" ] && echo yes || echo no)" "yes"
is "没有 disable normal 单元" "$(grep -c 'disable kde-hotspot-normal' "$MOCKLOG" 2>/dev/null || true)" "0"

section "F. autostart on 只启用当前模式的单元"
reset
: > "$STATE/disabled"
run autostart on
is "autostart on 成功" "$(jget ok)" "true"
is "清掉「保持关闭」标记" "$([ -e "$STATE/disabled" ] && echo yes || echo no)" "no"
mock_has "systemctl enable kde-hotspot.service kde-hotspot-dhcp.service" \
    && ok "并发模式启用主服务+DHCP" || no "并发模式启用主服务+DHCP" "$(grep enable "$MOCKLOG")"
mock_has "systemctl disable kde-hotspot-normal.service" \
    && ok "同时 disable 普通模式单元" || no "同时 disable 普通模式单元"
: > "$MOCKLOG"
cfg_set MODE normal
run autostart on
mock_has "systemctl enable kde-hotspot-normal.service" && ok "普通模式启用 normal 单元" || no "普通模式启用 normal 单元"
mock_has "systemctl disable kde-hotspot.service kde-hotspot-dhcp.service" \
    && ok "普通模式 disable 并发单元" || no "普通模式 disable 并发单元"
is "写普通模式自启标记" "$([ -e "$STATE/autostart-normal" ] && echo yes || echo no)" "yes"
run autostart off
is "autostart off 成功" "$(jget ok)" "true"
mock_has "systemctl disable kde-hotspot.service kde-hotspot-dhcp.service kde-hotspot-normal.service" \
    && ok "off 时三个单元都 disable" || no "off 时三个单元都 disable"

section "G. mode 切换：写配置保住行尾注释 + 停两套机制 + 关自启"
reset
rm -f "$CONF"
printf '# 注释行\nSSID=MyNet\nPASS="secret-pass-123"\nMODE=concurrent    # 模式说明\n' > "$CONF"
: > "$MOCKSTATE/active.kde-hotspot.service"
printf 'uuid-ap|kde-hotspot-normal|802-11-wireless|wlan0|yes\n' >> "$MOCKSTATE/nm.conns"
run mode normal
is "mode 成功" "$(jget ok)" "true"
is "MODE 已改" "$(grep -c '^MODE=normal' "$CONF")" "1"
contains "行尾注释保留" "$(grep '^MODE=' "$CONF")" "# 模式说明"
is "注释行保留" "$(grep -c '^# 注释行$' "$CONF")" "1"
is "行数不变（没有追加重复键）" "$(wc -l < "$CONF" | tr -d ' ')" "4"
mock_has "systemctl stop kde-hotspot.service kde-hotspot-dhcp.service" && ok "停并发服务" || no "停并发服务"
mock_has "nmcli connection down kde-hotspot-normal" && ok "停普通模式热点" || no "停普通模式热点"
mock_has "systemctl disable kde-hotspot.service" && ok "切换模式会关掉自启" || no "切换模式会关掉自启"
not_contains "提示里不再说自启被关闭" "$(jget message)" "自启已关闭"
# 自启原本开着 → 切换模式后应指向新模式，而不是被关掉
: > "$MOCKLOG"
: > "$MOCKSTATE/enabled.kde-hotspot-normal.service"
run mode concurrent
mock_has "systemctl enable kde-hotspot.service kde-hotspot-dhcp.service" \
    && ok "自启原本开着 → 新模式单元被启用" || no "自启原本开着 → 新模式单元被启用" "$(grep enable "$MOCKLOG")"
mock_has "systemctl disable kde-hotspot-normal.service" \
    && ok "旧模式单元被停用" || no "旧模式单元被停用"
# 自启原本关着 → 切换模式后仍然是关着
reset
: > "$MOCKLOG"
run mode normal
is "自启原本关着 → 不 enable 任何单元" "$(grep -c 'systemctl enable' "$MOCKLOG" 2>/dev/null || true)" "0"
run mode bogus
is "非法模式不输出 JSON" "$(jget ok)" "<no-json>"
is "非法模式 exit 2" "$RC" "2"

section "H. on：凭据校验 / 清关闭标记 / 服务失败要说出来"
reset
cfg_set PASS short
run on
is "短密码拒绝启动" "$(jget ok)" "false"
contains "给出原因" "$(jget message)" "8-63"
reset
: > "$STATE/disabled"
: > "$MOCKSTATE/active.kde-hotspot.service"
: > "$MOCKSTATE/active.kde-hotspot-dhcp.service"
run on
is "on 成功" "$(jget ok)" "true"
is "清掉关闭标记" "$([ -e "$STATE/disabled" ] && echo yes || echo no)" "no"
mock_has "systemctl start kde-hotspot.service kde-hotspot-dhcp.service" && ok "启动两个单元" || no "启动两个单元"
reset
: > "$MOCKSTATE/failstart.kde-hotspot.service"
run on
is "主服务起不来 → 失败" "$(jget ok)" "false"
contains "提示看 journalctl" "$(jget message)" "journalctl"
reset
: > "$MOCKSTATE/failstart.kde-hotspot-dhcp.service"
run on
is "DHCP 起不来 → 明确失败" "$(jget ok)" "false"
contains "指出 DHCP 问题" "$(jget message)" "DHCP"
reset
cfg_set SSID my-hotspot
run on
is "示例占位 SSID 拒绝启动" "$(jget ok)" "false"
contains "指出是占位值" "$(jget message)" "占位"

section "H2. 服务在「崩溃-自动重启」循环里：必须报失败（实机故障回归）"
reset
# 真实 systemd 里这就是 Restart=on-failure 且脚本立刻退出的样子：
# is-active 返回 0（activating），但根本没进入 running
printf 'activating:auto-restart\n' > "$MOCKSTATE/unitstate.kde-hotspot.service"
: > "$MOCKSTATE/active.kde-hotspot-dhcp.service"
run on
is "不报成功" "$(jget ok)" "false"
contains "提示看 journalctl" "$(jget message)" "journalctl"
contains "说清楚真实状态" "$(jget message)" "auto-restart"
run_status
is "status 里 concurrent_service_active 必须是 no（activating≠在跑）" "$(jget concurrent_service_active)" "no"
is "status 带上真实状态串（面板据此区分待命与失败）" "$(jget concurrent_service_state)" "activating/auto-restart"
# 对照：真正 active/running 时才算成功
reset
: > "$MOCKSTATE/active.kde-hotspot.service"
: > "$MOCKSTATE/active.kde-hotspot-dhcp.service"
run on
is "真 active/running 才算成功" "$(jget ok)" "true"

section "I. 普通模式 on：断开 Wi-Fi 并记下 UUID，off 时恢复"
reset
cfg_set MODE normal
run on
is "普通模式 on 成功" "$(jget ok)" "true"
is "记下原连接 UUID" "$(cat "$STATE/sta-conn.backup" 2>/dev/null)" "uuid-home"
mock_has "nmcli connection down uuid uuid-home" && ok "断开原 Wi-Fi 连接" || no "断开原 Wi-Fi 连接"
mock_has "nmcli connection add type wifi ifname wlan0 con-name kde-hotspot-normal" \
    && ok "创建热点 profile" || no "创建热点 profile" "$(grep 'connection add' "$MOCKLOG")"
mock_has "nmcli connection up kde-hotspot-normal" && ok "激活热点 profile" || no "激活热点 profile"
: > "$MOCKLOG"
printf 'MyNet\n' > "$MOCKSTATE/nm.ssid"
printf 'secret-pass-123\n' > "$MOCKSTATE/nm.psk"
printf 'uuid-ap|kde-hotspot-normal|802-11-wireless|wlan0|yes\n' >> "$MOCKSTATE/nm.conns"
run on
is "凭据一致时不重建 profile" "$(grep -c 'connection add' "$MOCKLOG")" "0"
: > "$MOCKLOG"
printf 'old-pass-123456\n' > "$MOCKSTATE/nm.psk"
run on
mock_has "nmcli connection delete kde-hotspot-normal" && ok "凭据变了就重建（删旧）" || no "凭据变了就重建（删旧）"
mock_has "connection add type wifi" && ok "凭据变了就重建（新建）" || no "凭据变了就重建（新建）"
reset
cfg_set MODE normal
printf 'uuid-home\n' > "$STATE/sta-conn.backup"
# 热点运行中：AP profile 是激活的，原来的 HomeWifi 是我们断开后才空着的
cat > "$MOCKSTATE/nm.conns" <<'EOD'
uuid-ap|kde-hotspot-normal|802-11-wireless|wlan0|yes
uuid-home|HomeWifi|802-11-wireless|wlan0|no
EOD
run off
mock_has "nmcli connection up uuid uuid-home" && ok "off 恢复原 Wi-Fi 连接" || no "off 恢复原 Wi-Fi 连接"
is "备份文件已清理" "$([ -e "$STATE/sta-conn.backup" ] && echo yes || echo no)" "no"
reset
cfg_set MODE normal
printf 'uuid-home\n' > "$STATE/sta-conn.backup"
printf 'uuid-other|OtherWifi|802-11-wireless|wlan0|yes\n' >> "$MOCKSTATE/nm.conns"
run off
not_contains "用户已连别的 Wi-Fi 时不抢回来" "$(cat "$MOCKLOG")" "connection up uuid uuid-home"

section "J. --pass-file 只接受调用者私有目录里的 600 普通文件"
reset
# 需要一个「不属于当前调用者」的公共目录。/tmp 在容器/沙箱里可能属于当前用户，
# 所以逐个探测；都不可用时报 skip（而不是假装通过）。
pubdir=""; pf=""
for c in /tmp /var/tmp; do
    [ -d "$c" ] || continue
    [ "$(stat -c %u "$c" 2>/dev/null)" = "$(id -u)" ] && continue
    # 还要真能写（/var/tmp 在某些沙箱里是只读挂载）
    if pf=$(mktemp "$c/kde-hotspot-pass.XXXXXX" 2>/dev/null); then pubdir=$c; break; fi
done
if [ -n "$pubdir" ]; then
    printf 'newpass-1234\n' > "$pf"; chmod 600 "$pf"
    run set-credentials NewName --pass-file "$pf"
    is "拒绝公共目录（$pubdir）下的密码文件" "$(jget ok)" "false"
    contains "说明目录不属于调用者" "$(jget message)" "目录"
    is "被拒绝的文件不删除" "$([ -e "$pf" ] && echo yes || echo no)" "yes"
    rm -f "$pf"
else
    printf '  skip 找不到「不属于当前用户」的公共目录，跳过公共目录用例\n'
fi
d="$WORK/kde-hotspot-pass.abc123"; mkdir -p "$d"; chmod 700 "$d"
printf 'newpass-1234\n' > "$d/pass"; chmod 644 "$d/pass"
run set-credentials NewName --pass-file "$d/pass"
is "拒绝 644 的密码文件" "$(jget ok)" "false"
contains "说明权限过宽" "$(jget message)" "权限"
printf 'newpass-1234\n' > "$d/real"; chmod 600 "$d/real"
ln -sf "$d/real" "$d/link"
run set-credentials NewName --pass-file "$d/link"
is "拒绝符号链接" "$(jget ok)" "false"
contains "说明是符号链接" "$(jget message)" "符号链接"
d2="$WORK/kde-hotspot-pass.xyz789"; mkdir -p "$d2"; chmod 777 "$d2"
printf 'newpass-1234\n' > "$d2/pass"; chmod 600 "$d2/pass"
run set-credentials NewName --pass-file "$d2/pass"
is "拒绝他人可写的目录" "$(jget ok)" "false"
contains "说明目录可被他人写" "$(jget message)" "他人写"
d3="$WORK/kde-hotspot-pass.ok0001"; mkdir -p "$d3"; chmod 700 "$d3"
printf 'newpass-1234\n' > "$d3/pass"; chmod 600 "$d3/pass"
run set-credentials "New Name" --pass-file "$d3/pass"
is "接受合法密码文件" "$(jget ok)" "true"
is "配置里的密码已更新" "$(cfg_get PASS)" "newpass-1234"
is "配置里的 SSID 已更新" "$(cfg_get SSID)" "New Name"
is "临时密码文件已删除" "$([ -e "$d3/pass" ] && echo yes || echo no)" "no"
is "临时目录已清理" "$([ -e "$d3" ] && echo yes || echo no)" "no"
d4="$WORK/kde-hotspot-pass.root01"; mkdir -p "$d4"; chmod 700 "$d4"
printf 'newpass-1234\n' > "$d4/pass"; chmod 600 "$d4/pass"
PKEXEC_UID_OVERRIDE=0
run set-credentials NewName --pass-file "$d4/pass"
PKEXEC_UID_OVERRIDE=""
is "PKEXEC_UID 未设置时要求 root 属主" "$(jget ok)" "false"
contains "说明属主不对" "$(jget message)" "属主"

section "K. set-credentials：只改名称 / stdin 传密码 / 重启热点"
reset
run set-credentials OnlyName
is "只改名称成功" "$(jget ok)" "true"
is "名称已写" "$(cfg_get SSID)" "OnlyName"
is "密码保持不变" "$(cfg_get PASS)" "secret-pass-123"
contains "提示下次生效" "$(jget message)" "下次"
: > "$MOCKLOG"
printf 'stdin-pass-999\n' | PATH="$BIN:$PATH" KDE_HOTSPOT_CONF="$CONF" PKEXEC_UID="$(id -u)" \
    "$CTL" set-credentials ViaStdin - > "$WORK/out.txt" 2> "$WORK/err.txt"
tail -1 "$WORK/out.txt" > "$OUTFILE"
is "从 stdin 读密码成功" "$(jget ok)" "true"
is "stdin 密码已写" "$(cfg_get PASS)" "stdin-pass-999"
# 待命中的并发服务（systemd 单元在跑但 ap0 还没信道）也要按新配置重启
reset
: > "$MOCKSTATE/active.kde-hotspot.service"
rm -f "$MOCKSTATE/ap.exists"
: > "$MOCKLOG"
run set-credentials StandbyName
mock_has "systemctl restart kde-hotspot.service kde-hotspot-dhcp.service" \
    && ok "待命中的并发服务也会重启" || no "待命中的并发服务也会重启" "$(grep restart "$MOCKLOG")"
contains "提示已重启" "$(jget message)" "重启"
# 普通模式运行中：停掉再按新配置起
reset
cfg_set MODE normal
printf 'uuid-ap|kde-hotspot-normal|802-11-wireless|wlan0|yes\n' >> "$MOCKSTATE/nm.conns"
: > "$MOCKLOG"
run set-credentials NormalName
mock_has "nmcli connection down kde-hotspot-normal" && ok "普通模式运行中会重启热点" || no "普通模式运行中会重启热点"
is "重启后配置是新的" "$(cfg_get SSID)" "NormalName"

section "L. cleanup：按 rules.state 记录拆规则（接口/网段改过也能清）"
reset
printf 'oldwlan ap9 10.9.9.0/24\n' > "$RUN/rules.state"
cfg_set STA_IF newwlan AP_IF ap0 AP_IP 10.233.33.1
# mock 是有状态的：先造出"系统上真实存在的残留规则"，才能验证 cleanup 真的拆掉了它们
cat > "$MOCKSTATE/ipt.rules" <<'EOD'
-t nat POSTROUTING -s 10.9.9.0/24 -o oldwlan -j MASQUERADE
FORWARD -i ap9 -o oldwlan -j ACCEPT
FORWARD -i oldwlan -o ap9 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-t nat POSTROUTING -s 10.233.33.0/24 -o newwlan -j MASQUERADE
FORWARD -i ap0 -o newwlan -j ACCEPT
EOD
run cleanup
is "cleanup 正常退出" "$RC" "0"
mock_has "iptables -t nat -D POSTROUTING -s 10.9.9.0/24 -o oldwlan -j MASQUERADE" \
    && ok "按记录拆旧的 MASQUERADE 规则" || no "按记录拆旧的 MASQUERADE 规则" "$(grep -- '-D' "$MOCKLOG" | head -2)"
mock_has "iptables -D FORWARD -i ap9 -o oldwlan -j ACCEPT" \
    && ok "按记录拆 FORWARD 规则" || no "按记录拆 FORWARD 规则"
mock_has "ip rule del from 10.9.9.0/24 lookup main" && ok "按记录删策略路由" || no "按记录删策略路由"
mock_has "iptables -t nat -D POSTROUTING -s 10.233.33.0/24 -o newwlan" \
    && ok "当前 config 的组合也清一遍" || no "当前 config 的组合也清一遍"
is "rules.state 已删除" "$([ -e "$RUN/rules.state" ] && echo yes || echo no)" "no"
is "规则表里不再有热点网段（真的拆干净）" "0" "$(grep -cE '10[.]9[.]9[.]0/24|10[.]233[.]33[.]0/24' "$MOCKSTATE/ipt.rules" 2>/dev/null || true)"
reset
printf 'bg\n' > "$STATE/band.backup"
printf 'uuid-home\n' > "$STATE/band.conn"
run cleanup
mock_has "nmcli connection modify uuid-home 802-11-wireless.band bg" && ok "恢复 Wi-Fi 频段偏好" || no "恢复 Wi-Fi 频段偏好"
mock_has "nmcli connection up uuid-home" && ok "恢复后重新连上" || no "恢复后重新连上"
is "备份已清理" "$([ -e "$STATE/band.backup" ] && echo yes || echo no)" "no"

section "L2. 上次开机留下的「保持关闭」标记：不再压制开机自启"
reset
: > "$STATE/disabled"
touch -d '2020-01-01 00:00:00' "$STATE/disabled"
: > "$MOCKSTATE/active.kde-hotspot.service"
: > "$MOCKSTATE/active.kde-hotspot-dhcp.service"
run_status
is "陈旧标记不算「已关闭」（重启后应听从开机自启）" "$(jget disabled)" "false"
reset
: > "$STATE/disabled"
run_status
is "本次开机写的标记仍算「已关闭」" "$(jget disabled)" "true"

section "N. sync-helpers：按 config 渲染 dnsmasq.conf（以前完全没测过）"
reset
rm -f "$DNSMASQ_FIXTURE"
: > "$MOCKLOG"
run sync-helpers
is "sync-helpers 正常退出" "$RC" "0"
contains "接口取 AP_IF" "$(cat "$DNSMASQ_FIXTURE" 2>/dev/null)" "interface=ap0"
contains "地址池取 DHCP_START/END" "$(cat "$DNSMASQ_FIXTURE" 2>/dev/null)" "dhcp-range=10.233.33.50,10.233.33.150,255.255.255.0,12h"
contains "网关取 AP_IP" "$(cat "$DNSMASQ_FIXTURE" 2>/dev/null)" "dhcp-option=3,10.233.33.1"
contains "DNS 取 DHCP_DNS" "$(cat "$DNSMASQ_FIXTURE" 2>/dev/null)" "dhcp-option=6,223.5.5.5,119.29.29.29"
contains "带 bind-dynamic（只绑热点接口，不与 resolved 抢 53）" "$(cat "$DNSMASQ_FIXTURE" 2>/dev/null)" "bind-dynamic"
is "文件权限 644（不含密钥）" "$(stat -c %a "$DNSMASQ_FIXTURE" 2>/dev/null)" "644"
: > "$MOCKLOG"
run sync-helpers
is "内容没变 → 不重启 DHCP 单元" "$(grep -c 'try-restart' "$MOCKLOG" 2>/dev/null || true)" "0"
cfg_set DHCP_START 60 DHCP_END 160
: > "$MOCKLOG"
run sync-helpers
contains "改了地址池就重新渲染" "$(cat "$DNSMASQ_FIXTURE")" "10.233.33.60,10.233.33.160"
mock_has "systemctl try-restart kde-hotspot-dhcp.service" && ok "内容变化后重启 DHCP 单元" || no "内容变化后重启 DHCP 单元"

section "O. 密码必须走 --pass-file / stdin（不再接受命令行密码）"
reset
run set-credentials NewName newpass-1234
is "拒绝命令行密码" "$(jget ok)" "false"
is "退出码 2" "$RC" "2"
contains "提示改用 --pass-file 或 -" "$(jget message)" "--pass-file"
is "配置没被改动" "$(cfg_get PASS)" "secret-pass-123"
run set-credentials NewName --pass-file /proc/self/environ
contains "拒绝 /proc 下的伪文件" "$(jget message)" "/proc"

section "P. 切模式要把上一套机制对 Wi-Fi 的副作用还回去"
# concurrent（可能把频段钉在 2.4G）→ normal：必须恢复频段偏好
reset
printf 'pg\n' > "$STATE/band.backup"
printf 'uuid-home\n' > "$STATE/band.conn"
: > "$MOCKLOG"
run mode normal
mock_has "nmcli connection modify uuid-home 802-11-wireless.band pg" \
    && ok "切走 concurrent 时恢复频段偏好" || no "切走 concurrent 时恢复频段偏好" "$(grep 'connection modify' "$MOCKLOG")"
# normal（断开了 Wi-Fi）→ concurrent：必须把原连接接回来
reset
cfg_set MODE normal
printf 'uuid-home\n' > "$STATE/sta-conn.backup"
# normal 模式的"开启"会把 Wi-Fi 断开：这里必须模拟成"未连接"，
# 否则 restore_sta_conn 会（正确地）认为用户已经连上了而跳过恢复
cat > "$MOCKSTATE/nm.conns" <<'EOD'
uuid-home|HomeWifi|802-11-wireless|wlan0|no
EOD
: > "$MOCKLOG"
run mode concurrent
mock_has "nmcli connection up uuid uuid-home" \
    && ok "切走 normal 时把 Wi-Fi 接回来" || no "切走 normal 时把 Wi-Fi 接回来"
# 恢复失败时：备份必须留着，日志不许说"已恢复"
reset
printf 'pg\n' > "$STATE/band.backup"
printf 'uuid-home\n' > "$STATE/band.conn"
: > "$MOCKSTATE/fail-band"
run cleanup
is "恢复失败时保留备份（否则永久钉在 2.4G）" "$([ -e "$STATE/band.backup" ] && echo 有 || echo 无)" "有"
is "备份也保留" "$([ -e "$STATE/band.conn" ] && echo 有 || echo 无)" "有"
not_contains "日志不许谎报已恢复" "$(cat "$WORK/out.txt")" "已恢复"
rm -f "$MOCKSTATE/fail-band"

section "Q. 配置读不到时：如实报 config_readable=false，不拿默认值冒充"
reset
chmod 000 "$CONF"
run_status
is "config_readable=false" "$(jget config_readable)" "false"
is "SSID 不给假值（空）" "$(jget hotspot.ssid)" ""
is "status 仍然是合法 JSON" "$(python3 -c 'import json,sys;json.load(open(sys.argv[1]));print("ok")' "$OUTFILE" 2>/dev/null || echo bad)" "ok"
chmod 600 "$CONF"

section "M. 其它：JSON 结果始终是一行、未知命令退出码 2"
reset
run off
is "动作类命令输出恰好一行 JSON" "$(wc -l < "$WORK/out.txt" | tr -d ' ')" "1"
run bogus
is "未知命令 exit 2" "$RC" "2"
run
is "无参数 exit 2" "$RC" "2"

printf '\n控制脚本测试：%s 通过，%s 失败\n' "$T_PASS" "$T_FAIL"
[ "$T_FAIL" -eq 0 ]
