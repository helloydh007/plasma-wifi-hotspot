#!/bin/bash
# 并发热点监督脚本：ap0 虚拟接口 + hostapd，与 Wi-Fi 客户端(STA)同信道并存。
#
# 本机硬件事实（实测）：
#  - AX201 + iwlwifi 固件监管域 self-managed，5GHz NO-IR：STA 在 5GHz 时无法并发发信标。
#  - 接口组合 #channels<=1：STA 与 AP 必须同信道。反向同样成立——
#    热点开着时 STA 连不上其他信道，所以 STA 离开热点信道时必须先停热点。
#
# 状态机：等 STA 进 2.4GHz → 起热点 → 盯着 STA；STA 离开该信道/断开 → 停热点 → 回去等。
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
IW=/usr/sbin/iw
IPT=/usr/sbin/iptables

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
    $IPT -t nat -C POSTROUTING -s "$AP_NET" -o "$STA_IF" -j MASQUERADE 2>/dev/null || \
        $IPT -t nat -I POSTROUTING -s "$AP_NET" -o "$STA_IF" -j MASQUERADE
    $IPT -C FORWARD -i "$AP_IF" -o "$STA_IF" -j ACCEPT 2>/dev/null || \
        $IPT -I FORWARD 1 -i "$AP_IF" -o "$STA_IF" -j ACCEPT
    $IPT -C FORWARD -i "$STA_IF" -o "$AP_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
        $IPT -I FORWARD 1 -i "$STA_IF" -o "$AP_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
}

HP=0
cleanup(){ [ "$HP" -gt 0 ] && kill "$HP" 2>/dev/null; exit 0; }
trap cleanup TERM INT

logged5g=0
loggedoff=0
while :; do
    # ---- 阶段1：等 STA 关联且在 2.4GHz（或被禁用/切到普通模式时静默等待）----
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
        if [ -z "$CH" ]; then
            sleep 5; logged5g=0; continue
        fi
        if [ "$CH" -gt 13 ] 2>/dev/null; then
            if [ "$logged5g" -eq 0 ]; then
                log "STA 在 5GHz(ch$CH)：本卡固件禁止 5GHz 并发热点，等待 Wi-Fi 切回 2.4GHz"
                logged5g=1
            fi
            sleep 5; continue
        fi
        break
    done
    logged5g=0
    log "STA 在 2.4GHz ch$CH → 启动热点（同信道并存）"
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
        printf 'hw_mode=g\n'
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
    misses=0
    while kill -0 "$HP" 2>/dev/null; do
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
