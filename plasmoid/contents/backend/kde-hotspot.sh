#!/bin/bash
# 并发热点监督脚本：ap0 虚拟接口 + hostapd，与 Wi-Fi 客户端(STA)同信道并存。
#
# 信道原则（与 linux-wifi-hotspot/create_ap 一致）：
#  - 不修改 STA 连接的频段/信道；热点直接跟随 STA 当前信道发信标（2.4G→hw_mode g，5G→a）。
#  - 接口组合 #channels<=1 的网卡上 STA 与 AP 必须同信道；STA 换信道/断开时
#    停掉热点并在新信道上重启（对客户端表现为同 SSID 的短暂掉线重连）。
#  - 只有固件/监管域**明确拒绝**当前信道时（典型：Intel LAR 自管监管域把 5GHz 全部
#    标为 NO-IR，hostapd 报 "Hardware does not support configured channel"）才按
#    FALLBACK_2G（默认 yes）把 STA 降到 2.4GHz 再起热点，频段偏好会备份、关闭热点时
#    由 ctl 恢复。hostapd 因其它原因（信道忙、驱动瞬时故障…）退出时不降频（评审 P1-5）。
#
# 状态机：等 STA 连接 → 在其信道起热点 → 盯着 STA；信道变化/断开 → 重启/停热点 → 回去等。
#
# 开关控制（由 kde-hotspot-ctl 写入）：
#  - /var/lib/kde-hotspot/disabled 存在  → 不启动热点（"保持关闭"）
#  - /etc/kde-hotspot/config 里 MODE=normal → 本脚本让位（普通模式由 NetworkManager 负责）
#
# 注意：配置只在启动时读一次。手改 config 里的 FALLBACK_2G/RULE_PRIO/COUNTRY 等
# 高级项后需要 `systemctl restart kde-hotspot` 才生效（改 SSID/密码走面板会自动重启）。
#
# 配置一律通过 kde-hotspot-config.sh 以纯数据方式读取，绝不 source。
set -u
# hostapd.conf 里有密码，默认权限收紧到 600
umask 077

CONF_LIB=/usr/local/lib/kde-hotspot/config.sh
if [ ! -r "$CONF_LIB" ]; then
    echo "[kde-hotspot] 缺少配置库 $CONF_LIB（请重跑 install.sh 或 deploy.sh）" >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$CONF_LIB"

CONF=$(hs_conf_path)
STATE=/var/lib/kde-hotspot
DISABLED="$STATE/disabled"
CLIENTS="$STATE/clients"
RUN=/run/kde-hotspot
RULESTATE="$RUN/rules.state"
AP_IF=${AP_IF:-ap0}
AP_IP=${AP_IP:-10.233.33.1}
# 策略路由优先级：必须高于代理软件（mihomo/Clash 用 9000 段）
RULE_PRIO=${RULE_PRIO:-8990}
IW=/usr/sbin/iw
IPT=/usr/sbin/iptables
NMCLI=/usr/bin/nmcli
CTL=/usr/local/sbin/kde-hotspot-ctl

log(){ echo "[kde-hotspot] $*"; }
mkdir -p "$RUN" "$STATE"

# ---------- 读配置（纯数据解析，见配置库）----------
hs_conf_load || log "读不到配置 $CONF，使用默认值"
SSID=${SSID:-}
PASS=${PASS:-}
MODE=${MODE:-concurrent}
COUNTRY=${COUNTRY:-}
# 网段以 AP_IP 为唯一数据源（旧实现里 AP_IP / AP_NET / 写死的 /24 三处各一份）
AP_NET=$(hs_derive_ap_net "$AP_IP" 2>/dev/null) || AP_NET=""
if [ -z "$AP_NET" ]; then
    log "AP_IP='$AP_IP' 不是合法 IPv4，按默认 10.233.33.1 处理"
    AP_IP=10.233.33.1
    AP_NET=10.233.33.0/24
fi

# STA_IF：留空/接口不存在时自动探测。优先取 NetworkManager 里"已连接"的 Wi-Fi 设备，
# 多网卡（尤其插了 USB 网卡）时才不会挑到一块空闲网卡（评审 §3.2）。
detect_sta_if(){
    local d=""
    d=$($NMCLI -t -f DEVICE,TYPE,STATE device status 2>/dev/null \
        | awk -F: -v ap="$AP_IF" '$2=="wifi" && $3=="connected" && $1!=ap {print $1; exit}')
    [ -n "$d" ] && { printf '%s' "$d"; return 0; }
    d=$($IW dev 2>/dev/null | awk -v ap="$AP_IF" '
        /Interface[ \t]/ { ifc=$2; next }
        ifc != "" && ifc != ap && $1 == "type" && $2 != "AP" { print ifc; exit }')
    [ -n "$d" ] && { printf '%s' "$d"; return 0; }
    return 1
}
STA_IF=${STA_IF:-}
if [ -z "$STA_IF" ] || ! $IW dev "$STA_IF" info >/dev/null 2>&1; then
    if _detected=$(detect_sta_if); then
        [ -n "$STA_IF" ] && log "配置的接口 $STA_IF 不存在，自动改用 $_detected"
        STA_IF=$_detected
    else
        STA_IF=${STA_IF:-wlan0}
    fi
fi

# 监管域：优先 config 的 COUNTRY，其次沿用系统当前监管域。
# 不再兜底成 CN（评审 P1-6）：监管域关系当地法规、可用频段与功率，公开发行的软件
# 不该替用户指定国家。取不到就不设，交给驱动当前设置。
if [ -z "$COUNTRY" ]; then
    COUNTRY=$($IW reg get 2>/dev/null | awk '/^country/{print $2; exit}' | tr -d ':')
fi
[ -n "$COUNTRY" ] || log "未取到监管域（可在 config 里显式设 COUNTRY=XX）；hostapd 用驱动当前设置"

# 上一轮异常退出（断电/被 kill）可能留下频段备份与残留规则：
# 启动时先清理一次，避免 Wi-Fi 被永久钉在 2.4GHz。
if [ -e "$STATE/band.backup" ]; then
    log "发现上次遗留的频段备份，先恢复 Wi-Fi 频段偏好"
    if [ -x "$CTL" ]; then
        "$CTL" cleanup >/dev/null 2>&1 || true
    fi
fi

sta_channel() {
    $IW dev 2>/dev/null | awk -v s="$STA_IF" '
        $0 ~ "Interface "s {f=1; next}
        f && /channel/ {print $2; exit}'
}

# 热点停止时清掉"在线客户端数"标记，免得面板继续显示旧数据
ap_stop_marks(){ rm -f "$CLIENTS" 2>/dev/null || true; }

# 在线客户端数：只有 root 能读 iw station dump，所以由本脚本写一份（0644）
# 给插件免特权读取。旧实现数 dnsmasq 租约：租约能留 12 小时（不等于在线），
# 路径还硬编码成 Debian 的 /var/lib/misc/dnsmasq.leases（非 Debian 恒为 0）。
write_clients(){
    local n
    n=$($IW dev "$AP_IF" station dump 2>/dev/null | grep -c '^Station ')
    printf '%s\n' "${n:-0}" > "$CLIENTS" 2>/dev/null || true
    chmod 0644 "$CLIENTS" 2>/dev/null || true
}

ensure_ap0() {
    if ! ip link show "$AP_IF" >/dev/null 2>&1; then
        local wiphy
        wiphy=$($IW dev "$STA_IF" info 2>/dev/null | awk '/^wiphy/{print $2}')
        $IW phy "phy${wiphy:-0}" interface add "$AP_IF" type __ap \
            || { log "创建 $AP_IF 失败"; return 1; }
        log "已创建 $AP_IF (type AP)"
    fi
    ip addr replace "$AP_IP/24" dev "$AP_IF" 2>/dev/null
    ip link set "$AP_IF" up
    sysctl -qw net.ipv4.ip_forward=1
    ensure_rules
}

# 把"实际用了哪套接口/网段"落盘：接口名或网段改过之后，ctl 关闭时按记录也能把
# 旧规则拆干净（否则残留，评审 §3.6-4）
record_rules_state(){
    printf '%s %s %s\n' "$STA_IF" "$AP_IF" "$AP_NET" > "$RULESTATE" 2>/dev/null || true
}

# NAT/转发规则。Docker 等软件重启时会清掉 FORWARD 链上的第三方规则并把策略
# 设为 DROP，导致热点客户端断网；因此除起 AP 时设置外，阶段2 每轮循环补检一次。
ensure_rules(){
    # 代理软件（Clash Verge / mihomo 等 TUN 模式）会插入 9000 段的策略路由，
    # 把流量导向其 TUN 并把默认路由屏蔽掉；热点客户端的转发包因此拿不到路由
    # （内核 IpOutNoRoutes 静默丢弃）——表现是"连上热点但无法上网"。
    # 给热点网段插一条更高优先级的规则，让它走主路由表直连上行（不经代理）。
    if ! ip rule show 2>/dev/null | grep -qF "$AP_NET lookup main"; then
        ip rule add from "$AP_NET" lookup main priority "$RULE_PRIO" 2>/dev/null || true
    fi
    $IPT -t nat -C POSTROUTING -s "$AP_NET" -o "$STA_IF" -j MASQUERADE 2>/dev/null || \
        $IPT -t nat -I POSTROUTING -s "$AP_NET" -o "$STA_IF" -j MASQUERADE
    $IPT -C FORWARD -i "$AP_IF" -o "$STA_IF" -j ACCEPT 2>/dev/null || \
        $IPT -I FORWARD 1 -i "$AP_IF" -o "$STA_IF" -j ACCEPT
    $IPT -C FORWARD -i "$STA_IF" -o "$AP_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
        $IPT -I FORWARD 1 -i "$STA_IF" -o "$AP_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    record_rules_state
}

# 5GHz 被固件拒绝时的自动回退：把 STA 降到 2.4GHz。
# 频段备份（band.backup/band.conn）与 ctl 共用，关闭热点时由 ctl restore_band 恢复。
# 备份里记的是连接 UUID（名字可能重复或被改，UUID 才稳定，评审 P1-3）。
force_sta_2g(){
    local c="" name=""
    read -r c name < <($NMCLI -t -f UUID,NAME,TYPE,DEVICE connection show --active 2>/dev/null \
        | awk -F: -v d="$STA_IF" '$3=="802-11-wireless" && $4==d {print $1, $2; exit}')
    [ -n "$c" ] || return 0
    if [ ! -e "$STATE/band.backup" ]; then
        $NMCLI -g 802-11-wireless.band connection show "$c" 2>/dev/null | head -1 > "$STATE/band.backup"
        echo "$c" > "$STATE/band.conn"
    fi
    $NMCLI connection modify "$c" 802-11-wireless.band bg 2>/dev/null || true
    $NMCLI connection up "$c" >/dev/null 2>&1 || true
    log "5GHz 热点被固件拒绝：已把 Wi-Fi '${name:-$c}' 切到 2.4GHz（频段偏好已备份，关闭热点时恢复）"
}

HP=0
cleanup(){
    [ "$HP" -gt 0 ] && kill "$HP" 2>/dev/null
    ap_stop_marks
    exit 0
}
trap cleanup TERM INT

loggedfail=0
loggedoff=0
while :; do
    # ---- 阶段1：等 STA 关联（任意频段，热点跟随其信道；禁用/普通模式时静默等待）----
    while :; do
        # 手动关闭：不启动热点
        if [ -e "$DISABLED" ]; then
            if [ "$loggedoff" -eq 0 ]; then
                log "已被手动关闭（$DISABLED 存在），不启动热点"
                loggedoff=1
            fi
            sleep 5; continue
        fi
        loggedoff=0
        # 凭据未设置/仍是示例占位值/含控制字符则不启动（绝不用公开已知或坏掉的凭据起热点）
        if hs_cred_problem >/dev/null; then
            sleep 10; continue
        fi
        # 普通模式下本脚本让位
        if [ "$MODE" = "normal" ]; then
            sleep 5; continue
        fi
        CH=$(sta_channel)
        [ -z "$CH" ] && { sleep 5; continue; }   # STA 未连接
        break
    done
    # 热点跟随 STA 信道：2.4G→g，5G→a（同 create_ap；不改 STA 的频段）
    HW=g
    [ "$CH" -le 14 ] 2>/dev/null || HW=a
    log "STA 在 ${HW} ch$CH → 热点跟随此信道启动（同信道并存）"
    if [ -n "$COUNTRY" ]; then
        $IW reg set "$COUNTRY" 2>/dev/null || true
    fi
    ensure_ap0 || { sleep 10; continue; }

    # 用 printf 生成配置：heredoc 会对 $SSID/$PASS 做变量展开和转义处理，
    # 名称/密码里含 $ ` \ 等字符时会被写坏
    {
        printf 'interface=%s\n' "$AP_IF"
        printf 'driver=nl80211\n'
        printf 'ssid=%s\n' "$SSID"
        # ieee80211d 需要 country_code，取不到监管域时两项都不写
        if [ -n "$COUNTRY" ]; then
            printf 'country_code=%s\n' "$COUNTRY"
            printf 'ieee80211d=1\n'
        fi
        printf 'hw_mode=%s\n' "$HW"
        printf 'channel=%s\n' "$CH"
        printf 'wpa=2\n'
        printf 'wpa_passphrase=%s\n' "$PASS"
        printf 'wpa_key_mgmt=WPA-PSK\n'
        printf 'rsn_pairwise=CCMP\n'
        printf 'ieee80211n=1\n'
        printf 'wmm_enabled=1\n'
        printf 'ht_capab=[SHORT-GI-20]\n'
    } > "$RUN/hostapd.conf"
    # 旧文件可能是宽松权限遗留的（umask 只管新建），补一次显式收紧
    chmod 600 "$RUN/hostapd.conf"

    # ---- 阶段2：跑热点，同时盯着 STA 是否仍在同一信道 ----
    log "启动 hostapd: $SSID @ ch$CH (网关 $AP_IP)"
    : > "$RUN/hostapd.log"; chmod 600 "$RUN/hostapd.log"
    /usr/sbin/hostapd -i "$AP_IF" "$RUN/hostapd.conf" >> "$RUN/hostapd.log" 2>&1 &
    HP=$!
    # 判断 hostapd 是"真的起来了"、"被固件/监管域拒绝"还是"在做 DFS 雷达检测"：
    #  - ap0 有信道 → 成功
    #  - 日志出现 Hardware does not support configured channel / Could not select hw_mode /
    #    Failed to set beacon parameters / Interface initialization failed / Channel is
    #    disabled → 明确拒绝该信道 → 可回退 2.4G
    #  - 日志出现 DFS/CAC → 这是 DFS 信道，需要 60 秒以上的雷达检测，此时延长等待而
    #    **不能**判定失败（旧实现用固定 8 秒超时，会在 DFS 信道上误报"固件拒绝"并
    #    把用户的 Wi-Fi 无谓地降到 2.4GHz）
    #  - 进程死了但日志里没有拒绝字样 → 只是失败，不改用户的频段（评审 P1-5）
    ok=0; refused=0; died=0; deadline=15; t=0
    while [ "$t" -lt "$deadline" ]; do
        if [ -n "$($IW dev "$AP_IF" info 2>/dev/null | awk '/channel/{print $2; exit}')" ]; then
            ok=1; break
        fi
        if grep -qE 'Hardware does not support configured channel|Could not select hw_mode|Failed to set beacon parameters|Interface initialization failed|Channel is disabled' "$RUN/hostapd.log" 2>/dev/null; then
            refused=1; break
        fi
        if grep -qiE 'DFS|radar|CAC' "$RUN/hostapd.log" 2>/dev/null; then
            if [ "$deadline" -lt 150 ]; then
                log "ch$CH 是 DFS 信道，hostapd 正在做雷达检测（CAC 通常 60 秒），延长等待"
                deadline=150
            fi
        fi
        if ! kill -0 "$HP" 2>/dev/null; then
            died=1; break
        fi
        sleep 1; t=$((t+1))
    done
    if [ "$ok" -ne 1 ]; then
        local_reason=$(grep -m1 -E 'Hardware does not support|Could not select hw_mode|Failed to set beacon|Interface initialization failed|Unable to setup interface|Channel is disabled' "$RUN/hostapd.log" 2>/dev/null)
        if [ "$loggedfail" != "$CH" ]; then
            if [ "$died" -eq 1 ]; then
                log "热点未能在 ch$CH 发信标：hostapd 已退出（${local_reason:-无更多日志}）"
            else
                log "热点未能在 ch$CH 发信标：${local_reason:-hostapd 未就绪（等待 ${t}s）}"
            fi
            loggedfail=$CH
        fi
        kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null; HP=0
        ip link set "$AP_IF" down 2>/dev/null
        ap_stop_marks
        # 只有确认是"固件/监管域拒绝"才回退；其它失败保持用户频段不变
        if [ "$refused" -eq 1 ] && [ "$CH" -gt 14 ] && [ "${FALLBACK_2G:-yes}" != "no" ]; then
            force_sta_2g
            # 给面板一个"发生过回退"的标记（status JSON 的 fallback 字段）。
            # 无敏感信息，设为可读，插件才能免特权读到。
            printf '%s\n' "$CH" > "$STATE/fallback" 2>/dev/null || true
            chmod 0644 "$STATE/fallback" 2>/dev/null || true
        elif [ "$refused" -ne 1 ] && [ "$deadline" -ge 150 ]; then
            log "ch$CH 的 DFS 雷达检测未在等待窗口内完成，暂不发信标（不降频）"
        elif [ "$died" -eq 1 ]; then
            sleep 5
        fi
        sleep 3
        continue
    fi
    loggedfail=0
    # 5G 热点成功发信标：此前"回退到 2.4G"的标记已过时，清除
    if [ "$HW" = a ]; then
        rm -f "$STATE/fallback"
    fi
    write_clients
    misses=0; tick=0
    while kill -0 "$HP" 2>/dev/null; do
        # 规则自检降频：每 ~15 秒一次。原实现每 3 秒跑 ip rule show + 3 次
        # iptables -C（每天约 11 万次进程创建，且每次都要抢 xtables 锁）。
        tick=$((tick+1))
        [ $((tick % 5)) -eq 1 ] && ensure_rules
        [ $((tick % 2)) -eq 1 ] && write_clients
        # 手动关闭 → 立即停
        if [ -e "$DISABLED" ]; then
            log "收到关闭指令，停止热点"
            kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null; HP=0
            ip link set "$AP_IF" down 2>/dev/null
            ap_stop_marks
            break
        fi
        if [ "$MODE" = "normal" ]; then
            log "模式已切到 normal，停止并发热点"
            kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null; HP=0
            ip link set "$AP_IF" down 2>/dev/null
            ap_stop_marks
            break
        fi
        NOW=$(sta_channel)
        if [ "$NOW" != "$CH" ]; then
            misses=$((misses+1))
            if [ "$misses" -ge 2 ]; then
                log "STA 离开 ch$CH（当前: ${NOW:-断开}），暂停热点以便 Wi-Fi 重连"
                kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null
                HP=0
                ip link set "$AP_IF" down 2>/dev/null
                ap_stop_marks
                break
            fi
        else
            misses=0
        fi
        sleep 3
    done
    [ "$HP" -gt 0 ] && { wait "$HP" 2>/dev/null; HP=0; }
    log "回到等待状态"
    sleep 3
done
