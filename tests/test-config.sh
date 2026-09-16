#!/bin/bash
# 配置库回归测试（不需要 root、不依赖任何系统服务）
#
# 覆盖评审报告里 §3.1 的全部字符用例与格式兼容性：
#   - 旧格式（未加引号、带行尾注释）必须继续可读
#   - 空格 / 撇号 / $ / 反斜杠 / 双引号 / # / 前后空白 / 中文 的写入→回读往返
#   - 值中的 $(...) 被当作字面文本，绝不执行（原实现 source 配置会导致 root RCE）
#   - 未知键被忽略、缺失键取不到值、行尾注释在改值后被保留
#   - 凭据校验：长度、控制字符、示例占位值
# 本测试必须原样包含 $ / $(...) / 反引号 / 单引号等字面量（那正是被测对象），
# 也不直接分析被 source 的库（库在 CI 里单独 shellcheck）
# shellcheck disable=SC2016,SC1091
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/backend/kde-hotspot-config.sh"

# 计数器不能叫 PASS/FAIL：PASS 是配置键，hs_conf_load 会把它设成密码字符串
T_PASS=0
T_FAIL=0
ok(){ T_PASS=$((T_PASS + 1)); printf '  ok   %s\n' "$1"; }
bad(){ T_FAIL=$((T_FAIL + 1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
is(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "期望 [$2] 实得 [$3]"; fi; }

if [ ! -r "$LIB" ]; then
    echo "缺少 $LIB —— 测试无法运行（实现尚未完成）" >&2
    exit 1
fi
# shellcheck source=../backend/kde-hotspot-config.sh
. "$LIB" || exit 1

TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT
export KDE_HOTSPOT_CONF="$TMP/config"

conf_reset(){
    cat > "$KDE_HOTSPOT_CONF" <<'EOF'
# 行首注释
STA_IF=wlp0s20f3     # 上行 Wi-Fi 接口；留空或接口不存在时后端会尝试自动探测
AP_IF=ap0
AP_IP=10.233.33.1
AP_NET=10.233.33.0/24
SSID=My Hotspot
PASS=pa$$word\123
MODE=concurrent      # concurrent=并发模式 / normal=普通模式
EOF
}

echo "== A) 旧格式（未加引号 + 行尾注释）必须继续可读 =="
conf_reset
unset SSID PASS MODE STA_IF AP_NET 2>/dev/null
hs_conf_load
is "STA_IF 取到值且行尾注释被剥离" "wlp0s20f3" "${STA_IF:-}"
is "带空格的值完整保留" "My Hotspot" "${SSID:-}"
is "带 \$ 与反斜杠的值按字面保留" 'pa$$word\123' "${PASS:-}"
is "带行尾注释的 MODE 取到裸值" "concurrent" "${MODE:-}"
is "AP_NET 里的 /24 不被当注释" "10.233.33.0/24" "${AP_NET:-}"

echo "== B) 未知键被忽略（不进 shell 变量）=="
cat >> "$KDE_HOTSPOT_CONF" <<'EOF'
EVIL=1
$(touch /tmp/should-never-run)
EOF
unset EVIL 2>/dev/null
hs_conf_load
is "未知键不会被加载" "" "${EVIL:-}"

echo "== C) 恶意值不得被执行（原 source 实现的 root RCE 路径）=="
CANARY="$TMP/PWNED"
rm -f "$CANARY" "$TMP/CANARY_subst"
cat > "$KDE_HOTSPOT_CONF" <<EOF
SSID=x\$(touch $CANARY)
PASS=\`touch $TMP/CANARY_backtick\`
EOF
hs_conf_load
is "命令替换按字面读出" "x\$(touch $CANARY)" "${SSID:-}"
is "\$(...) 未被执行" "no" "$([ -e "$CANARY" ] && echo yes || echo no)"
is "反引号未被执行" "no" "$([ -e "$TMP/CANARY_backtick" ] && echo yes || echo no)"

echo "== D) 写入→回读往返（含报告 §3.1 的 4 组字符）=="
values=(
    'My Hotspot'
    'x$(touch '"$TMP"'/CANARY_subst)'
    'WiFi$5Bar'
    "John's Net"
    'back\slash'
    $'end\\'
    'semi;colon & and|pipe && rm -rf /'
    'quote"double'
    'hash # tag'
    ' leading space'
    'trailing space '
    '热点名称'
    "''"
    "'"
    '"'
    '=equal=sign'
    'a=b=c'
)
for v in "${values[@]}"; do
    conf_reset
    if ! hs_conf_set SSID "$v"; then bad "写入失败: [$v]"; continue; fi
    unset SSID
    hs_conf_load
    is "往返: [$v]" "$v" "${SSID:-}"
done

echo "== E) 含引号的值写入后仍是合法配置（引号被转义而非截断）=="
conf_reset
hs_conf_set SSID "John's Net" PASS 'p@ss"word#'
raw="$(grep '^SSID=' "$KDE_HOTSPOT_CONF")"
case "$raw" in
    "SSID='"*"'") ok "含撇号的值以单引号包裹写出" ;;
    *) bad "含撇号的值应加引号" "实得 [$raw]" ;;
esac
case "$raw" in
    *"\\'s Net'") ok "撇号在引号内被 \\' 转义" ;;
    *) bad "撇号未转义" "实得 [$raw]" ;;
esac
unset SSID PASS
hs_conf_load
is "撇号值回读正确" "John's Net" "${SSID:-}"
is "同时改的密码回读正确" 'p@ss"word#' "${PASS:-}"

echo "== F) 改值保留其它行与该行的行尾注释 =="
conf_reset
before_lines="$(wc -l < "$KDE_HOTSPOT_CONF")"
hs_conf_set MODE normal
is "MODE 已改" "normal" "$(hs_conf_get MODE)"
case "$(grep '^MODE=' "$KDE_HOTSPOT_CONF")" in
    *"# concurrent=并发模式 / normal=普通模式"*) ok "MODE 行尾注释被保留" ;;
    *) bad "行尾注释丢失" "实得 [$(grep '^MODE=' "$KDE_HOTSPOT_CONF")]" ;;
esac
is "未改动的 AP_IP 保持不变" "10.233.33.1" "$(hs_conf_get AP_IP)"
is "未改动的 SSID 保持不变" "My Hotspot" "$(hs_conf_get SSID)"
is "行尾注释保留后文件行数不变" "$before_lines" "$(wc -l < "$KDE_HOTSPOT_CONF")"

echo "== G) 追加不存在的键 =="
conf_reset
hs_conf_set COUNTRY DE
is "新键已追加且可取回" "DE" "$(hs_conf_get COUNTRY)"

echo "== H) 缺失键 =="
if hs_conf_get NOPE >/dev/null; then bad "缺失键应返回非零" ; else ok "缺失键返回非零"; fi
is "缺失键取到空串" "" "$(hs_conf_get NOPE)"

echo "== I) 值为空 =="
conf_reset
hs_conf_set PASS ""
is "空值回读为空" "" "$(hs_conf_get PASS)"

echo "== J) 凭据校验 =="
cred_case(){ # cred_case <描述> <期望有问题?> <SSID> <PASS>
    local desc="$1" want="$2" s="$3" p="$4" got
    SSID="$s"; PASS="$p"
    if hs_cred_problem >/dev/null; then got=bad; else got=ok; fi
    is "$desc" "$want" "$got"
}
cred_case "合法凭据通过" ok 'My Hotspot' 'passw0rd123'
cred_case "空 SSID 被拒" bad '' 'passw0rd123'
cred_case "空密码被拒" bad 'My Hotspot' ''
cred_case "SSID 33 字符被拒" bad "$(printf 'a%.0s' {1..33})" 'passw0rd123'
cred_case "SSID 32 字符通过" ok "$(printf 'a%.0s' {1..32})" 'passw0rd123'
cred_case "密码 7 位被拒" bad 'My Hotspot' 'passw0r'
cred_case "密码 63 位通过" ok 'My Hotspot' "$(printf 'a%.0s' {1..63})"
cred_case "密码 64 位被拒" bad 'My Hotspot' "$(printf 'a%.0s' {1..64})"
cred_case "SSID 含控制字符被拒" bad $'tab\there' 'passw0rd123'
cred_case "密码含控制字符被拒" bad 'My Hotspot' $'pass\tword'
cred_case "示例占位 SSID 被拒" bad 'my-hotspot' 'passw0rd123'
cred_case "示例占位密码被拒" bad 'My Hotspot' 'change-me-now'
cred_case "含空格/撇号/\$/反斜杠的合法值通过" ok "John's Net \$5\\x" 'p@ss w0rd\1'

echo "== K) 环境变量不能冒充配置（root 场景的边界）=="
conf_reset                      # 该配置里没有 COUNTRY
COUNTRY=DE
hs_conf_load
is "配置里没有的键：残留的环境变量必须被清掉" "" "${COUNTRY:-}"
MODE=normal
hs_conf_load
is "环境变量不能覆盖配置文件" "concurrent" "${MODE:-}"

echo "== L) 网段派生（AP_IP 为唯一数据源）=="
is "10.233.33.1 -> 10.233.33.0/24" "10.233.33.0/24" "$(hs_derive_ap_net 10.233.33.1)"
is "192.168.9.254 -> 192.168.9.0/24" "192.168.9.0/24" "$(hs_derive_ap_net 192.168.9.254)"
if hs_derive_ap_net "not-an-ip" >/dev/null 2>&1; then bad "非法 AP_IP 应返回非零"; else ok "非法 AP_IP 返回非零"; fi
if hs_derive_ap_net "" >/dev/null 2>&1; then bad "空 AP_IP 应返回非零"; else ok "空 AP_IP 返回非零"; fi

echo "== M) 同一键写多次：读（get/load）与写回语义必须一致 =="
# 旧实现是 `source` 配置 → 后出现的值生效。这一点要保留（用户习惯在文件末尾覆盖），
# 但 get / load / set 三者必须一致，否则面板显示的值和实际生效的值会不一样。
cat > "$KDE_HOTSPOT_CONF" <<'EOF'
SSID=first-ssid
PASS=first-pass-1234
MODE=concurrent
SSID=second-ssid
EOF
is "hs_conf_get 取最后一次出现的值" "second-ssid" "$(hs_conf_get SSID)"
hs_conf_load
is "hs_conf_load 与 hs_conf_get 一致（最后一次生效）" "second-ssid" "${SSID:-}"
hs_conf_set SSID final-ssid || bad "hs_conf_set 失败"
is "写回后同一键只留一行（重复行被合并）" "1" "$(grep -c '^SSID=' "$KDE_HOTSPOT_CONF")"
is "写回后没有残留旧值" "0" "$(grep -cE '=(first|second)-ssid$' "$KDE_HOTSPOT_CONF")"
is "写回后的值可回读（get）" "final-ssid" "$(hs_conf_get SSID)"
hs_conf_load
is "写回后的值可回读（load）" "final-ssid" "${SSID:-}"
is "其它键不受影响" "first-pass-1234" "$(hs_conf_get PASS)"

echo "== N) 可选键缺省时由库统一补默认值（否则 set -u 下引用会直接崩）=="
# 实机故障复盘：kde-hotspot.sh 先设了 RULE_PRIO=${RULE_PRIO:-8990}，随后 hs_conf_load
# 会把白名单键全部 unset 再只装文件里有的键 → 默认值被清掉 → 引用时"未绑定变量"。
# 修法是把默认值收进库里：只要键没写（或写成空），load 之后一定是可用值。
cat > "$KDE_HOTSPOT_CONF" <<'EOF'
SSID=MyNet
PASS=secret-pass-123
MODE=concurrent
STA_IF=wlan0
EOF
hs_conf_load
is "RULE_PRIO 缺失 → 默认 8990" "8990" "${RULE_PRIO:-}"
is "FALLBACK_2G 缺失 → 默认 yes" "yes" "${FALLBACK_2G:-}"
is "NORMAL_CHANNEL 缺失 → 默认 6" "6" "${NORMAL_CHANNEL:-}"
is "DHCP_START 缺失 → 默认 50" "50" "${DHCP_START:-}"
is "DHCP_END 缺失 → 默认 150" "150" "${DHCP_END:-}"
is "DHCP_DNS 缺失 → 默认值" "223.5.5.5,119.29.29.29" "${DHCP_DNS:-}"
is "AP_IF 缺失 → 默认 ap0" "ap0" "${AP_IF:-}"
is "AP_IP 缺失 → 默认 10.233.33.1" "10.233.33.1" "${AP_IP:-}"
is "COUNTRY 缺失 → 空（不硬编任何国家）" "" "${COUNTRY:-}"
cat > "$KDE_HOTSPOT_CONF" <<'EOF'
SSID=MyNet
PASS=secret-pass-123
RULE_PRIO=
EOF
hs_conf_load
is "写成空值也当没写（否则会拼出 priority \"\" 这种坏命令）" "8990" "${RULE_PRIO:-}"

echo "== O) 运行时标记的「是否属于本次开机」判定 =="
# 用途：用户点了"关闭热点"后写的标记，只在**本次开机内**生效。
# 否则用户同时开着"开机自启"，重启后热点反而起不来（关热点不该动开机自启）。
M="$TMP/marker"
: > "$M"
if hs_marker_is_current "$M"; then ok "刚写的标记 = 本次开机内有效"; else bad "刚写的标记应有效"; fi
touch -d '2020-01-01 00:00:00' "$M"
if hs_marker_is_current "$M"; then bad "上次开机写的标记不该继续有效"; else ok "陈旧标记被判为无效"; fi
if hs_marker_is_current "$TMP/not-exist"; then bad "不存在的标记应无效"; else ok "不存在的标记无效"; fi
if hs_marker_is_current ""; then bad "空路径应无效"; else ok "空路径无效"; fi

echo
echo "配置库测试：$T_PASS 通过，$T_FAIL 失败"
[ "$T_FAIL" -eq 0 ]
