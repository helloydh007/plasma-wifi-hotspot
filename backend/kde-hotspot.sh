#!/bin/bash
# 并发热点监督脚本：ap0 虚拟接口 + hostapd，与 Wi-Fi 客户端(STA)同信道并存。
#
# 信道原则（与 linux-wifi-hotspot/create_ap 一致）：
#  - 不修改 STA 连接的频段/信道；热点直接跟随 STA 当前信道发信标（2.4G→hw_mode g，5G→a）。
#  - 接口组合 #channels<=1 的网卡上 STA 与 AP 必须同信道；STA 换信道/断开时
#    停掉热点并在新信道上重启（对客户端表现为同 SSID 的短暂掉线重连）。
#  - 若固件拒绝当前信道（典型：Intel LAR 自管监管域把 5GHz 全部标为 NO-IR，
#    hostapd 报 "Hardware does not support configured channel"），则按 FALLBACK_2G
#    （默认 yes）自动把 STA 降到 2.4GHz 再起热点，频段偏好会备份、关闭热点时由 ctl 恢复。
#
# 状态机：等 STA 连接 → 在其信道起热点 → 盯着 STA；信道变化/断开 → 重启/停热点 → 回去等。
#
# 开关控制（由 kde-hotspot-ctl 写入）：
#  - /var/lib/kde-hotspot/disabled 存在  → 不启动热点（"保持关闭"）
#  - /etc/kde-hotspot/config 里 MODE=normal → 本脚本让位（普通模式由 NetworkManager 负责）
set -u
# hostapd.conf 里有密码，默认权限收紧到 600
umask 077
CONF=/etc/kde-hotspot/config
[ -r "$CONF" ] && . "$CONF"
STA_IF=${STA_IF:-wlp0s20f3}
AP_IF=${AP_IF:-ap0}
AP_IP=${AP_IP:-10.233.33.1}
AP_NET=${AP_NET:-10.233.33.0/24}
SSID=${SSID:-}
PASS=${PASS:-}
MODE=${MODE:-concurrent}
STATE=/var/lib/kde-hotspot
DISABLED="$STATE/disabled"
RUN=/run/kde-hotspot
# 策略路由优先级：必须高于代理软件（mihomo/Clash 用 9000 段）
RULE_PRIO=${RULE_PRIO:-8990}
IW=/usr/sbin/iw
IPT=/usr/sbin/iptables
NMCLI=/usr/bin/nmcli

log(){ echo "[kde-hotspot] $*"; }
mkdir -p "$RUN" "$STATE"

sta_channel() {
    $IW dev 2>/dev/null | awk -v s="$STA_IF" '
        $0 ~ "Interface "s {f=1; next}
        f && /channel/ {print $2; exit}'
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
}

# 5GHz 被固件拒绝时的自动回退：把 STA 降到 2.4GHz。
# 频段备份（band.backup/band.conn）与 ctl 共用，关闭热点时由 ctl restore_band 恢复。
force_sta_2g(){
    local c
    c=$($NMCLI -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null \
        | awk -F: -v d="$STA_IF" '$2=="802-11-wireless" && $3==d {print $1; exit}')
    [ -n "$c" ] || return 0
    if [ ! -e "$STATE/band.backup" ]; then
        $NMCLI -g 802-11-wireless.band connection show "$c" 2>/dev/null | head -1 > "$STATE/band.backup"
        echo "$c" > "$STATE/band.conn"
    fi
    $NMCLI connection modify "$c" 802-11-wireless.band bg 2>/dev/null || true
    $NMCLI connection up "$c" >/dev/null 2>&1 || true
    log "5GHz 热点被固件拒绝：已把 Wi-Fi '$c' 切到 2.4GHz（频段偏好已备份，关闭热点时恢复）"
}

HP=0
cleanup(){ [ "$HP" -gt 0 ] && kill "$HP" 2>/dev/null; exit 0; }
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
        # 未配置 SSID/密码则不启动（避免用默认值起热点）
        if [ -z "${SSID:-}" ] || [ "${#PASS}" -lt 8 ]; then
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
    $IW reg set CN
    ensure_ap0 || { sleep 10; continue; }

    # 用 printf 生成配置：heredoc 会对 $SSID/$PASS 做变量展开和转义处理，
    # 名称/密码里含 $ ` \ 等字符时会被写坏
    {
        printf 'interface=%s\n' "$AP_IF"
        printf 'driver=nl80211\n'
        printf 'ssid=%s\n' "$SSID"
        printf 'country_code=CN\n'
        printf 'ieee80211d=1\n'
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
    /usr/sbin/hostapd -i "$AP_IF" "$RUN/hostapd.conf" &
    HP=$!
    # 确认 AP 真的发信标了：固件拒绝信道时 hostapd 会退出或 ap0 一直无信道
    #（典型是 Intel LAR 下 5GHz 全 NO-IR）。此时按 FALLBACK_2G 回退。
    ok=0
    for _ in 1 2 3 4 5 6 7 8; do
        kill -0 "$HP" 2>/dev/null || break
        if [ -n "$($IW dev "$AP_IF" info 2>/dev/null | awk '/channel/{print $2; exit}')" ]; then
            ok=1; break
        fi
        sleep 1
    done
    if [ "$ok" -ne 1 ]; then
        if [ "$loggedfail" -ne "$CH" ]; then
            log "热点无法在 ch$CH 发信标（硬件/固件拒绝该信道）"
            loggedfail=$CH
        fi
        kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null; HP=0
        ip link set "$AP_IF" down 2>/dev/null
        if [ "$CH" -gt 14 ] && [ "${FALLBACK_2G:-yes}" != "no" ]; then
            force_sta_2g
            # 给面板一个"发生过回退"的标记（status JSON 的 fallback 字段）。
            # 无敏感信息，设为可读，插件才能免特权读到。
            printf '%s\n' "$CH" > "$STATE/fallback" 2>/dev/null || true
            chmod 0644 "$STATE/fallback" 2>/dev/null || true
        fi
        sleep 3
        continue
    fi
    loggedfail=0
    # 5G 热点成功发信标：此前"回退到 2.4G"的标记已过时，清除
    [ "$HW" = a ] && rm -f "$STATE/fallback"
    misses=0
    while kill -0 "$HP" 2>/dev/null; do
        ensure_rules
        # 手动关闭 → 立即停
        if [ -e "$DISABLED" ]; then
            log "收到关闭指令，停止热点"
            kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null; HP=0
            ip link set "$AP_IF" down 2>/dev/null
            break
        fi
        if [ "$MODE" = "normal" ]; then
            log "模式已切到 normal，停止并发热点"
            kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null; HP=0
            ip link set "$AP_IF" down 2>/dev/null
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
