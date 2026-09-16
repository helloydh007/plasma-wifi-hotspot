#!/bin/bash
# kde-hotspot.sh（并发模式监督脚本）端到端测试 —— 全 mock：不需要 root、不需要网卡、
# 不会真的改网络（ip/iptables/sysctl/nmcli/hostapd 全是 mock），可以在 CI 里跑。
#
# 为什么必须有这套测试：控制脚本（kde-hotspot-ctl）有 mock 测试，但监督脚本一直没有，
# 于是下面这类 bug 直接漏到了用户机器上（2026-09-16 实机故障）：
#   配置里没写 RULE_PRIO（config.example 里本来就是注释掉的）→ 脚本第 44 行设的默认值
#   被后面的 hs_conf_load（它会先 unset 所有白名单键）清掉 → `set -u` 下第 154 行
#   "${RULE_PRIO}" 未绑定变量 → 脚本 87ms 就 exit 1 → systemd 重试 5 次后彻底失败，
#   而面板只看"服务是不是 active"，于是显示成开着，用户却完全连不上。
#
# ok/no 的 A && B || C 是刻意写法（ok/no 恒返回 0）；调试输出里的 ls 只给人看。
# shellcheck disable=SC2015,SC2012
#
# 用法：bash tests/test-supervisor.sh
# 红-绿自检：git show HEAD:backend/kde-hotspot.sh > /tmp/old-sup
#            SUP_SRC=/tmp/old-sup bash tests/test-supervisor.sh
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
SUP_SRC="${SUP_SRC:-$REPO/backend/kde-hotspot.sh}"
LIB="$REPO/backend/kde-hotspot-config.sh"
WORK=$(mktemp -d)
BIN="$WORK/bin"
STATE="$WORK/state"
RUN="$WORK/run"
CONF="$WORK/config"
MOCKLOG="$WORK/mock.log"
MS="$WORK/mockstate"
SUP="$WORK/kde-hotspot.sh"
cleanup_all(){ [ -n "${KEEP_WORK:-}" ] && { echo "（现场保留在 $WORK）"; return 0; }; rm -rf "$WORK"; }
trap cleanup_all EXIT

export MOCKLOG MOCKSTATE="$MS"
export MOCK_STA_IF=wlan0 MOCK_AP_IF=ap0

T_PASS=0; T_FAIL=0
ok(){ T_PASS=$((T_PASS + 1)); printf '  ok   %s\n' "$1"; }
no(){
    T_FAIL=$((T_FAIL + 1)); printf '  FAIL %s\n' "$1"
    [ -n "${2:-}" ] && printf '       %s\n' "$2"
    if [ -n "${DBG:-}" ]; then
        printf '       --- 监督脚本输出 ---\n'; sed 's/^/       /' "$WORK/out.txt" 2>/dev/null | tail -12
        printf '       --- mock 调用 ---\n'; tail -12 "$MOCKLOG" 2>/dev/null | sed 's/^/       /'
        printf '       --- 状态目录 ---\n'; ls -l "$STATE" "$RUN" 2>/dev/null | sed 's/^/       /'
    fi
}
is(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "期望 [$3] 实际 [$2]"; fi; }
contains(){ case "$2" in *"$3"*) ok "$1" ;; *) no "$1" "[$2] 中不含 [$3]" ;; esac; }
not_contains(){ case "$2" in *"$3"*) no "$1" "[$2] 中不应含 [$3]" ;; *) ok "$1" ;; esac; }
section(){ printf '\n== %s ==\n' "$1"; }

# ------------------------------------------------------------------ mock 工具
write_mocks(){
    mkdir -p "$BIN"

    # iw：信道状态由 hostapd mock 写；ap0 只有在"有信道"时才算真的起来了
    cat > "$BIN/iw" <<'EOF'
#!/bin/bash
printf 'iw %s\n' "$*" >> "$MOCKLOG"
S=$MOCKSTATE
AP=${MOCK_AP_IF:-ap0}
case "${1:-}" in
  dev)
    if [ -z "${2:-}" ]; then
        printf 'phy#0\n\tInterface %s\n\t\ttype managed\n' "${MOCK_STA_IF:-wlan0}"
        [ -n "$(cat "$S/sta.channel" 2>/dev/null)" ] && \
            printf '\t\tchannel %s (5200 MHz)\n' "$(cat "$S/sta.channel")"
        if [ -n "$(cat "$S/ap.channel" 2>/dev/null)" ]; then
            printf '\tInterface %s\n\t\ttype AP\n\t\tchannel %s (2437 MHz)\n' "$AP" "$(cat "$S/ap.channel")"
        fi
        exit 0
    fi
    case "${3:-}" in
      info)
        if [ "$2" = "$AP" ]; then
            [ -e "$S/ap.exists" ] || exit 1
            [ -n "$(cat "$S/ap.channel" 2>/dev/null)" ] && \
                printf 'Interface %s\n\twiphy 0\n\tchannel %s\n' "$2" "$(cat "$S/ap.channel")"
            exit 0
        fi
        printf 'Interface %s\n\twiphy 0\n' "$2"; exit 0 ;;
      station)
        n=$(cat "$S/ap.stations" 2>/dev/null || echo 0)
        i=0
        while [ "$i" -lt "$n" ]; do
            printf 'Station aa:bb:cc:dd:ee:0%s (on %s)\n' "$i" "$2"
            i=$((i + 1))
        done
        exit 0 ;;
    esac
    exit 0 ;;
  phy)
    for a in "$@"; do [ "$a" = "add" ] && : > "$S/ap.exists"; done
    exit 0 ;;
  reg)
    # 默认能读到监管域 CN；放 $MS/noreg 则模拟"读不到"
    if [ "${2:-}" = "get" ] && [ ! -e "$S/noreg" ]; then printf 'country CN: DFS-ETSI\n'; fi
    exit 0 ;;
esac
exit 0
EOF

    # ip：ap0 的 up/down 与信道状态联动（down 会丢信道，和真实一样）
    cat > "$BIN/ip" <<'EOF'
#!/bin/bash
printf 'ip %s\n' "$*" >> "$MOCKLOG"
S=$MOCKSTATE
AP=${MOCK_AP_IF:-ap0}
case "$*" in
  "link show $AP") [ -e "$S/ap.exists" ] && exit 0 || exit 1 ;;
  "link set $AP down") rm -f "$S/ap.channel"; exit 0 ;;
  "link set $AP up") : > "$S/ap.exists"; exit 0 ;;
  "rule show") cat "$S/iprules" 2>/dev/null; exit 0 ;;
  "rule add"*) printf '%s\n' "$*" >> "$S/iprules"; exit 0 ;;
esac
exit 0
EOF

    # hostapd：成功→写信道并常驻；被拒绝→打固件拒绝日志后退出；其它失败→直接退出
    cat > "$BIN/hostapd" <<'EOF'
#!/bin/bash
printf 'hostapd %s\n' "$*" >> "$MOCKLOG"
S=$MOCKSTATE
conf=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -i) shift ;;
        -*) ;;
        *) conf=$1 ;;
    esac
    shift
done
ch=$(grep -m1 '^channel=' "$conf" 2>/dev/null | cut -d= -f2)
printf 'hostapd-conf ch=%s mode=%s\n' "$ch" "$(grep -m1 '^hw_mode=' "$conf" 2>/dev/null | cut -d= -f2)" >> "$MOCKLOG"
echo $$ > "$S/hostapd.pid"
if [ -e "$S/refuse.$ch" ] || [ -e "$S/refuse.all" ]; then
    echo "Configuration file: $conf"
    echo "Could not select hw_mode and channel. (-3)"
    echo "Hardware does not support configured channel"
    exit 1
fi
if [ -e "$S/die.$ch" ] || [ -e "$S/die.all" ]; then
    echo "random driver hiccup"
    exit 1
fi
if [ -e "$S/dfs.$ch" ]; then
    echo "DFS start CAC on channel $ch"
    while :; do /bin/sleep 0.2; done
fi
printf '%s\n' "$ch" > "$S/ap.channel"
while :; do /bin/sleep 0.2; done
EOF

    # sysctl：只记录，绝不真的改内核
    cat > "$BIN/sysctl" <<'EOF'
#!/bin/bash
printf 'sysctl %s\n' "$*" >> "$MOCKLOG"
exit 0
EOF

    # iptables：-C 一律回答"规则不在"，好让 -I 真正执行
    cat > "$BIN/iptables" <<'EOF'
#!/bin/bash
printf 'iptables %s\n' "$*" >> "$MOCKLOG"
case "$*" in *" -C "*) exit 1 ;; esac
exit 0
EOF

    # nmcli：device status / connection show --active / -g band / 改频段
    cat > "$BIN/nmcli" <<'EOF'
#!/bin/bash
printf 'nmcli %s\n' "$*" >> "$MOCKLOG"
S=$MOCKSTATE
fields=""; get=no
while [ "$#" -gt 0 ]; do
    case "$1" in
        -t|--terse|-s|--show-secrets) ;;
        -f|--fields) shift; fields=${1:-} ;;
        -g|--get-values) shift; fields=${1:-}; get=yes ;;
        *) break ;;
    esac
    shift
done
cmd="$*"
# 改频段偏好 = STA 真的换频段（2.4G↔5G）
case "$cmd" in
  *"802-11-wireless.band bg"*) printf 'bg\n' > "$S/band"; printf '6\n' > "$S/sta.channel"; exit 0 ;;
  *"802-11-wireless.band a"*)  printf 'a\n'  > "$S/band"; printf '40\n' > "$S/sta.channel"; exit 0 ;;
esac
case "$cmd" in
  "device status"*) cat "$S/nm.devices" 2>/dev/null; exit 0 ;;
esac
if [ "$get" = yes ]; then
    [ "${fields##*.}" = band ] && cat "$S/band" 2>/dev/null
    exit 0
fi
case "$cmd" in
  "connection show --active"*)
      while IFS='|' read -r uuid name type dev act; do
          [ "${act:-}" = yes ] || continue
          out=""
          for f in ${fields//,/ }; do
              case "$f" in
                  UUID) v=$uuid ;; NAME) v=$name ;; TYPE) v=$type ;;
                  DEVICE) v=$dev ;; *) v=$name ;;
              esac
              out="${out:+$out:}$v"
          done
          printf '%s\n' "$out"
      done < "$S/nm.conns"
      exit 0 ;;
esac
exit 0
EOF

    # sleep：把脚本里的 sleep 3/5/10 缩短，测试才跑得快。
    # 不要设得太小：mock 全部是短命进程，sleep 太小会让监督脚本每秒 fork 几百次。
    cat > "$BIN/sleep" <<'EOF'
#!/bin/bash
exec /bin/sleep 0.15
EOF

    # 监督脚本启动时若发现残留频段备份会调用 ctl cleanup —— 这里给个桩
    cat > "$BIN/kde-hotspot-ctl" <<'EOF'
#!/bin/bash
printf 'ctl %s\n' "$*" >> "$MOCKLOG"
exit 0
EOF

    chmod +x "$BIN"/*
}

# 把绝对路径声明与硬编码的 hostapd 路径换成本测试环境
patch_sup(){
    sed -e "s|^CONF_LIB=.*|CONF_LIB=$LIB|" \
        -e "s|^STATE=.*|STATE=$STATE|" \
        -e "s|^RUN=.*|RUN=$RUN|" \
        -e "s|^IW=.*|IW=$BIN/iw|" \
        -e "s|^IPT=.*|IPT=$BIN/iptables|" \
        -e "s|^NMCLI=.*|NMCLI=$BIN/nmcli|" \
        -e "s|^CTL=.*|CTL=$BIN/kde-hotspot-ctl|" \
        -e "s|/usr/sbin/hostapd|$BIN/hostapd|" \
        "$SUP_SRC" > "$SUP"
    chmod +x "$SUP"
    grep -q "^IW=$BIN/iw$" "$SUP" || { echo "补丁失败：IW 未替换"; exit 1; }
    if grep -nE '^[A-Z_]+=' "$SUP" | grep -qE '=/usr/|=/var/|=/run/'; then
        echo "补丁失败：仍指向真实路径"; grep -nE '^[A-Z_]+=' "$SUP"; exit 1
    fi
    if grep -q '/usr/sbin/hostapd' "$SUP"; then echo "补丁失败：hostapd 路径未替换"; exit 1; fi
}

cfg_set(){
    KDE_HOTSPOT_CONF="$CONF" bash -c '. "$1"; shift; hs_conf_set "$@"' _ "$LIB" "$@"
    chmod 600 "$CONF"
}

# 一段"必填 + 常用"的基础配置（不写任何可选键，那正是 A 段要测的）
cfg_base(){
    cfg_set STA_IF wlan0 AP_IP 10.233.33.1 SSID MyNet PASS secret-pass-123 MODE concurrent "$@"
}

reset(){
    stop_all
    rm -rf "$STATE" "$RUN" "$MS"
    mkdir -p "$STATE" "$RUN" "$MS"
    : > "$MOCKLOG"
    : > "$CONF"
    : > "$MS/iprules"
    printf 'wlan0:wifi:connected\n' > "$MS/nm.devices"
    printf 'uuid-home|HomeWifi|802-11-wireless|wlan0|yes\n' > "$MS/nm.conns"
    printf 'pg\n' > "$MS/band"
    printf '3\n' > "$MS/ap.stations"
    printf '6\n' > "$MS/sta.channel"      # 默认 STA 在 2.4G ch6
}

# 收掉本测试起的所有进程（路径都带本次 $WORK，前缀唯一，不会误杀别的进程）
stop_all(){
    [ -n "${SUP_PID:-}" ] && kill "$SUP_PID" 2>/dev/null
    pkill -f "$SUP" 2>/dev/null
    pkill -f "$BIN/hostapd" 2>/dev/null
    sleep 0.3
    SUP_PID=""
}

# run_sup [秒数]：跑一段时间，判断"脚本是否还活着"（未绑定变量那种崩会立刻退出）
run_sup(){
    local t=${1:-3}
    PATH="$BIN:$PATH" KDE_HOTSPOT_CONF="$CONF" "$SUP" > "$WORK/out.txt" 2>&1 &
    SUP_PID=$!
    sleep "$t"
    if kill -0 "$SUP_PID" 2>/dev/null; then ALIVE=yes; else ALIVE=no; fi
    stop_all
}
# 运行中抓现场：有些产物会在退出时被 trap 有意清掉（例如在线客户端数标记），
# 所以断言这些必须在运行中快照，而不是等它结束。
SNAP="$WORK/snap"
run_snap(){  # run_snap [运行秒数]：运行中抓现场（有些产物退出时会被 trap 有意清掉）
    local t=${1:-3}
    rm -rf "$SNAP"; mkdir -p "$SNAP/run" "$SNAP/state" "$SNAP/ms"
    PATH="$BIN:$PATH" KDE_HOTSPOT_CONF="$CONF" "$SUP" > "$WORK/out.txt" 2>&1 &
    SUP_PID=$!
    sleep "$t"
    if kill -0 "$SUP_PID" 2>/dev/null; then ALIVE=yes; else ALIVE=no; fi
    cp -a "$RUN/." "$SNAP/run/" 2>/dev/null
    cp -a "$STATE/." "$SNAP/state/" 2>/dev/null
    cp -a "$MS/." "$SNAP/ms/" 2>/dev/null
    stop_all
}
snap(){ cat "$SNAP/$1" 2>/dev/null; }
mock_has(){ grep -qF -- "$1" "$MOCKLOG"; }
mock_count(){ grep -cF -- "$1" "$MOCKLOG" 2>/dev/null || true; }
conf_line(){ grep -m1 "^$1=" "$RUN/hostapd.conf" 2>/dev/null | cut -d= -f2-; }

write_mocks
patch_sup

# ==========================================================================
section "A. 配置里缺可选键时不能崩（实机故障的直接回归）"
reset
# 只写"必填 + 常用"的键：RULE_PRIO / FALLBACK_2G / NORMAL_CHANNEL / DHCP_* 全都不写
cfg_base
run_sup 3
is "跑满观察窗口仍然活着（没有因未绑定变量退出）" "$ALIVE" "yes"
not_contains "日志里不该出现未绑定变量" "$(cat "$WORK/out.txt")" "未绑定"
is "hostapd 真的被拉起来了" "$(mock_count 'hostapd -i ap0')" "1"
is "hostapd.conf 按 STA 信道生成（2.4G→hw_mode=g）" "$(conf_line hw_mode)" "g"
is "hostapd.conf 的 channel" "$(conf_line channel)" "6"
is "hostapd.conf 的 ssid" "$(conf_line ssid)" "MyNet"
is "hostapd.conf 用系统当前监管域（config 没写时 iw reg get 得到 CN）" "$(conf_line country_code)" "CN"
mock_has "iw reg set CN" && ok "把监管域下发给驱动" || no "把监管域下发给驱动"
mock_has "ip rule add from 10.233.33.0/24 lookup main priority 8990" \
    && ok "策略路由用默认优先级 8990" || no "策略路由用默认优先级 8990" "$(grep 'rule add' "$MOCKLOG")"
mock_has "iptables -t nat -I POSTROUTING -s 10.233.33.0/24 -o wlan0 -j MASQUERADE" \
    && ok "装 NAT 规则" || no "装 NAT 规则" "$(grep MASQUERADE "$MOCKLOG")"
contains "规则状态按实际接口/网段落盘" "$(cat "$RUN/rules.state" 2>/dev/null)" "wlan0 ap0 10.233.33.0/24"
run_snap 3
is "客户端数写出来（3 个 station）" "$(snap state/clients)" "3"
is "客户端数文件权限 644（供免特权 status 读）" "$(stat -c %a "$SNAP/state/clients" 2>/dev/null)" "644"
is "hostapd.conf 权限 600（含密码）" "$(stat -c %a "$RUN/hostapd.conf" 2>/dev/null)" "600"
contains "日志说明跟随信道" "$(cat "$WORK/out.txt")" "STA 在 g ch6"

section "A2. 读不到监管域时不写 country_code（不硬编国家）"
reset
: > "$MS/noreg"
cfg_base
run_sup 3
is "hostapd.conf 不写 country_code" "$(conf_line country_code)" ""
contains "日志说明没取到监管域" "$(cat "$WORK/out.txt")" "未取到监管域"

section "B. 配置里显式写的值优先于默认值"
reset
cfg_base RULE_PRIO 9111
run_sup 3
mock_has "ip rule add from 10.233.33.0/24 lookup main priority 9111" \
    && ok "用配置里的 RULE_PRIO=9111" || no "用配置里的 RULE_PRIO=9111" "$(grep 'rule add' "$MOCKLOG")"
not_contains "不再用默认 8990" "$(cat "$MOCKLOG")" "priority 8990"

section "C. 5GHz 被固件拒绝 → 自动回退 2.4G（且不改其它失败情形）"
reset
printf '40\n' > "$MS/sta.channel"       # STA 在 5G ch40
: > "$MS/refuse.40"                     # 固件拒绝 5G 热点
cfg_base
DBG=1 run_snap 6
mock_has "hostapd-conf ch=40 mode=a" && ok "先按 STA 的 5G 信道尝试" || no "先按 STA 的 5G 信道尝试" "$(grep 'hostapd-conf' "$MOCKLOG")"
mock_has "nmcli connection modify uuid-home 802-11-wireless.band bg" \
    && ok "确认被拒绝后把 Wi-Fi 降到 2.4G" || no "确认被拒绝后把 Wi-Fi 降到 2.4G" "$(grep nmcli "$MOCKLOG" | head -3)"
is "写了 fallback 标记（面板据此提示用户）" "$(snap state/fallback)" "40"
is "回退后 STA 已经换成 2.4G" "$(snap ms/sta.channel)" "6"
mock_has "hostapd-conf ch=6 mode=g" && ok "回退后按 2.4G 重新起 hostapd" || no "回退后按 2.4G 重新起 hostapd" "$(grep 'hostapd-conf' "$MOCKLOG")"
is "ap0 有信道（=真的在发信标）" "$(snap ms/ap.channel)" "6"

section "D. FALLBACK_2G=no：不为了热点动用户的 Wi-Fi"
reset
printf '40\n' > "$MS/sta.channel"
: > "$MS/refuse.40"
cfg_base FALLBACK_2G no
run_sup 4
not_contains "不调用 nmcli 改频段" "$(cat "$MOCKLOG")" "802-11-wireless.band bg"
is "STA 仍在 5G" "$(cat "$MS/sta.channel")" "40"
is "没有 fallback 标记" "$(cat "$STATE/fallback" 2>/dev/null || echo 无)" "无"

section "E. 非「拒绝」类失败：不降频（只记日志，等下轮重试）"
reset
printf '40\n' > "$MS/sta.channel"
: > "$MS/die.40"                        # hostapd 直接退出，日志里没有拒绝字样
cfg_base
DBG=1 run_snap 5
not_contains "不改用户频段" "$(cat "$MOCKLOG")" "802-11-wireless.band bg"
contains "日志说明 hostapd 退出了" "$(cat "$WORK/out.txt")" "hostapd 已退出"
is "没有 fallback 标记" "$(snap state/fallback || echo 无)" "无"

section "F. DFS 信道：延长等待，不误判为「固件拒绝」"
reset
printf '100\n' > "$MS/sta.channel"      # 5G DFS 信道
: > "$MS/dfs.100"
cfg_base
DBG=1 run_snap 3
contains "识别出 DFS/CAC 并延长等待" "$(cat "$WORK/out.txt")" "雷达检测"
not_contains "不因为没有立刻发信标就降频" "$(cat "$MOCKLOG")" "802-11-wireless.band bg"

section "G. 手动关闭（保持关闭标记）与坏凭据：绝不起热点"
reset
: > "$STATE/disabled"
run_sup 3
is "不启动 hostapd" "$(mock_count 'hostapd -i ap0')" "0"
contains "日志说明被手动关闭" "$(cat "$WORK/out.txt")" "已被手动关闭"
reset
cfg_set STA_IF wlan0 AP_IP 10.233.33.1 SSID my-hotspot PASS change-me-now MODE concurrent
run_sup 3
is "示例占位凭据不启动 hostapd" "$(mock_count 'hostapd -i ap0')" "0"
is "也不写 hostapd.conf" "$([ -e "$RUN/hostapd.conf" ] && echo 有 || echo 无)" "无"

section "G2. 上次开机留下的「保持关闭」标记：忽略并清除，照常发信标"
# 这条对应"用户开着开机自启 → 重启后热点应该照常起来"：
# 关热点时写的标记只在本次开机内有效，陈旧标记必须被忽略
reset
cfg_base
: > "$STATE/disabled"
touch -d '2020-01-01 00:00:00' "$STATE/disabled"
run_snap 3
is "陈旧标记被忽略 → 照常发信标" "$(snap ms/ap.channel)" "6"
is "陈旧标记被清掉" "$([ -e "$STATE/disabled" ] && echo 有 || echo 无)" "无"
contains "日志说明标记已过期" "$(cat "$WORK/out.txt")" "已过期"

section "H. 运行中收到关闭指令 / 模式切换：停 hostapd 并把 ap0 放倒"
reset
cfg_base
# 先正常起来，3 秒后创建 disabled 标记，再等一会看它是否收手
PATH="$BIN:$PATH" KDE_HOTSPOT_CONF="$CONF" "$SUP" > "$WORK/out2.txt" 2>&1 &
PID=$!
SUP_PID=$PID
sleep 2                                  # 先让它真的发上信标
BEFORE=$(cat "$MS/ap.channel" 2>/dev/null)
: > "$STATE/disabled"                    # 模拟用户在面板点"关闭"
sleep 2
AFTER=$(cat "$MS/ap.channel" 2>/dev/null)
is "关闭前确实在发信标" "$BEFORE" "6"
is "收到关闭指令后停止发信标（ap0 信道被清）" "${AFTER:-无}" "无"
if kill -0 "$PID" 2>/dev/null; then
    ok "监督脚本继续待命（进程不退出，由 systemd 负责停）"
else
    no "监督脚本继续待命" "进程已退出"
fi
SUP_PID="$PID"; stop_all
contains "日志说明收到关闭指令" "$(cat "$WORK/out2.txt")" "收到关闭指令"
mock_has "ip link set ap0 down" && ok "把 ap0 放倒" || no "把 ap0 放倒"
is "客户端数标记被清掉" "$([ -e "$STATE/clients" ] && echo 有 || echo 无)" "无"

printf '\n监督脚本测试：%s 通过，%s 失败\n' "$T_PASS" "$T_FAIL"
[ "$T_FAIL" -eq 0 ]
