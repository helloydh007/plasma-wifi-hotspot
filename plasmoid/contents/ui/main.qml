import QtQuick
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support

PlasmoidItem {
    id: root

    // 后端控制入口（polkit 规则已授权免密码）
    readonly property string ctl: "/usr/local/sbin/kde-hotspot-ctl"

    // 状态
    property var st: ({})
    property var deps: []
    property bool busy: false
    property string message: ""
    // 后端已接受"开启"指令、但热点还没发出信标（要建 ap0、起 hostapd，
    // 固件拒绝 5G 时还得等 Wi-Fi 降频重连）。此期间按钮保持"执行中"。
    property bool awaitingHotspot: false
    property string lastAction: ""
    readonly property int upTimeoutSec: 90

    // ---------- 派生状态 ----------
    readonly property bool ready: typeof st.mode === "string"
    readonly property bool isOff: st.disabled === true
    readonly property bool hotRunning: !!st.hotspot && st.hotspot.running === "yes"
    readonly property string mode: ready ? st.mode : "concurrent"
    readonly property string wifiSsid: (st.wifi && st.wifi.ssid) ? st.wifi.ssid : ""
    readonly property string wifiBand: (st.wifi && st.wifi.band) ? st.wifi.band : ""
    readonly property string wifiCh: (st.wifi && st.wifi.channel) ? String(st.wifi.channel) : ""
    readonly property string hotBand: (st.hotspot && st.hotspot.band) ? st.hotspot.band : ""
    readonly property string hotCh: (st.hotspot && st.hotspot.channel) ? String(st.hotspot.channel) : ""
    readonly property string autostartState: st.autostart ? st.autostart : "off"
    readonly property int clients: (st.hotspot && st.hotspot.clients) ? st.hotspot.clients : 0
    readonly property string hotspotSsid: (st.hotspot && st.hotspot.ssid) ? st.hotspot.ssid : ""
    readonly property string hotspotPass: (st.hotspot && st.hotspot.pass) ? st.hotspot.pass : ""
    property bool showPass: false
    // 5G 被固件拒绝、已自动回退 2.4G（监督脚本写入的状态标记）
    readonly property bool fallback: !!(st.hotspot && st.hotspot.fallback === true)

    readonly property string stateText: !ready ? i18n("Backend unavailable") : (isOff ? i18nc("The hotspot is switched off", "Off") : (hotRunning ? i18n("Running") : i18nc("Wi-Fi not on 2.4GHz yet, hotspot not beaconing", "Standby")))
    readonly property string bandText: hotRunning
        ? ((hotBand || "2.4G") + (hotCh ? " ch" + hotCh : ""))
        : (wifiBand ? (wifiBand + (wifiCh ? " ch" + wifiCh : "")) : "")
    readonly property string labelText: isOff ? i18nc("Short tray label", "Off") : ((mode === "normal" ? "AP " : "") + bandText)

    readonly property var missingDeps: deps.filter(function (d) { return !d.ok })
    readonly property var missingPkgs: {
        var map = { "/usr/sbin/hostapd": "hostapd", "/usr/sbin/dnsmasq": "dnsmasq" }
        var out = []
        for (var i = 0; i < missingDeps.length; i++) {
            var p = missingDeps[i].path
            if (map[p] && out.indexOf(map[p]) < 0) out.push(map[p])
        }
        return out
    }
    readonly property bool backendMissing: {
        var f = ["/usr/local/sbin/kde-hotspot-ctl", "/usr/local/sbin/kde-hotspot.sh",
                 "/etc/systemd/system/kde-hotspot.service"]
        for (var i = 0; i < f.length; i++) {
            for (var j = 0; j < missingDeps.length; j++) if (missingDeps[j].path === f[i]) return true
        }
        return false
    }
    readonly property string backendDir: Qt.resolvedUrl("../backend/deploy.sh").toString().replace("file://", "")

    // 图标统一用热点图标；关闭/后端不可用时在右下角叠红色 ✕ 徽标
    // （不用 network-wireless-disconnected——那是"WiFi+叉"，容易和断网混淆）
    readonly property string baseIcon: "network-wireless-hotspot"
    readonly property bool offBadge: !ready || isOff
    Plasmoid.icon: root.baseIcon
    Plasmoid.status: PlasmaCore.Types.ActiveStatus
    // 托盘里只显示图标，所以把频段/信道放进悬浮提示
    toolTipMainText: i18n("Wi-Fi hotspot: %1", stateText)
    toolTipSubText: hotRunning
        ? (i18n("Hotspot %1 %2 ch%3", hotspotSsid, (hotBand || ""), (hotCh ? String(hotCh) : ""))
           + (clients > 0 ? "　" + i18np("%1 device", "%1 devices", clients) : "")
           + (fallback ? "　" + i18n("(2.4GHz fallback)") : ""))
        : (mode === "normal"
            ? i18n("Normal mode: enabling will disconnect Wi-Fi")
            : (wifiSsid ? i18n("Wi-Fi %1 %2 ch%3", wifiSsid, wifiBand, (wifiCh ? String(wifiCh) : "")) : i18n("Wi-Fi not connected")))

    // ---------- 命令 ----------
    // status 只做只读探测（iw/nmcli/systemctl + 读配置），**刻意不走 pkexec**：
    // pkexec 每次都会 fork 一个 root 进程并建立 polkit/PAM 会话，按秒轮询等于
    // 每天数万次；配置与状态标记已授予当前用户只读权限（见 backend/deploy.sh），
    // 因此直接以用户身份运行即可。需要特权的操作（on/off/mode/…）仍走 pkexec。
    readonly property string statusCmd: ctl + " status"
    readonly property var depsPaths: [
        "/usr/sbin/hostapd",
        "/usr/sbin/dnsmasq",
        "/usr/sbin/iw",
        "/usr/sbin/iptables",
        "/usr/local/sbin/kde-hotspot.sh",
        "/usr/local/sbin/kde-hotspot-ctl",
        "/etc/kde-hotspot/config",
        "/etc/kde-hotspot/dnsmasq.conf",
        "/etc/systemd/system/kde-hotspot.service",
        "/etc/systemd/system/kde-hotspot-dhcp.service",
        "/usr/share/polkit-1/actions/org.kde.hotspotctl.policy",
        "/etc/NetworkManager/conf.d/99-kde-hotspot-ap0.conf"
    ]
    readonly property string depsCmd: "sh -c 'for p in " + depsPaths.join(" ")
        + "; do if [ -e $p ]; then echo OK $p; else echo MISS $p; fi; done; "
        + "if [ -r /etc/kde-hotspot/config ]; then echo OK 配置可读(免特权状态); "
        + "else echo MISS 配置不可读-重跑 install.sh 授权; fi; "
        + "if pkcheck --action-id org.kde.hotspotctl.run --process $$ >/dev/null 2>&1; "
        + "then echo OK polkit-免密授权; else echo MISS polkit-免密授权; fi'"

    // ---------- 数据源 ----------
    // executable 引擎的关键行为：对已连接过的 source 名，reconnect 只回放缓存、
    // 不会重新执行命令（曾经导致托盘状态永不更新）。因此：
    //  - 周期刷新用引擎自带的 interval 轮询同一个 source；
    //  - 手动立即刷新/一次性查询追加 "# 序号" 构造唯一 source 强制真正执行，
    //    拿到结果后立即断开。
    property int oneShotSeq: 0

    // pollInterval 配置项单位是"秒"（可能取不到默认值 undefined→NaN，显式兜底）
    readonly property int pollInterval: {
        var p = Number(Plasmoid.configuration.pollInterval)
        if (!isFinite(p) || p < 2) { p = 5 }
        return p
    }

    P5Support.DataSource {
        id: statusSource
        engine: "executable"
        connectedSources: [root.statusCmd]
        // 引擎的 interval 单位是**毫秒**（且 executable 引擎最小轮询间隔 1000ms），
        // 曾经漏乘 1000 → 5 被当 5ms 用、被抬到 1000ms，变成每秒一次查询。
        interval: root.pollInterval * 1000
        onNewData: (sourceName, data) => {
            if (data.stdout && data.stdout.length > 0) {
                try { root.st = JSON.parse(data.stdout) }
                catch (e) { root.st = ({}) }
            }
            // 热点真正发出信标了 → 结束"开启中"状态
            if (root.awaitingHotspot && root.hotRunning) {
                upTimer.stop()
                root.awaitingHotspot = false
                var where = (root.hotBand || "") + (root.hotCh ? " ch" + root.hotCh : "")
                root.message = i18n("Hotspot is up: %1  %2", root.hotspotSsid, where)
            }
            // 一次性查询用完即断；固定 source 留给 interval 轮询
            if (sourceName !== root.statusCmd) {
                Qt.callLater(() => { statusSource.disconnectSource(sourceName) })
            }
        }
    }

    // "开启"后等待热点就绪的超时兜底（Wi-Fi 掉线、固件异常等情况下不会永远卡住）
    Timer {
        id: upTimer
        interval: root.upTimeoutSec * 1000
        repeat: false
        onTriggered: {
            if (!root.awaitingHotspot) { return }
            root.awaitingHotspot = false
            root.message = i18n("Hotspot did not come up within %1 s — check journalctl -u kde-hotspot", root.upTimeoutSec)
        }
    }

    P5Support.DataSource {
        id: actionSource
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            root.busy = false
            // 优先解析控制脚本输出的一行 JSON（{ok,message}）。
            // 不依赖 exitCode 的类型——executable 引擎里它可能是字符串 "0"
            var ok = (data.exitCode === 0 || data.exitCode === "0")
            var msg = ""
            var out = (data.stdout || "").trim()
            if (out.length > 0) {
                try {
                    var r = JSON.parse(out.split("\n").pop())
                    if (typeof r.ok === "boolean") { ok = r.ok; msg = r.message || "" }
                } catch (e) { }
            }
            if (!msg) {
                msg = (data.stderr || "").trim().split("\n").pop()
                    || (ok ? i18n("Done") : i18n("see journalctl -u kde-hotspot"))
            }
            root.message = ok ? msg : i18n("Failed: %1", msg)
            // 后端已受理"开启"：热点真正发信标前一直保持"开启中"
            if (ok && root.lastAction === "on") {
                root.awaitingHotspot = true
                root.message = i18n("Turn-on accepted — waiting for the hotspot to beacon…")
                upTimer.restart()
            }
            Qt.callLater(() => { actionSource.disconnectSource(sourceName) })
            root.refreshStatus()
        }
    }

    P5Support.DataSource {
        id: depsSource
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            if (data.stdout) {
                root.deps = data.stdout.trim().split("\n").filter(function (l) { return l.length > 0 })
                    .map(function (l) {
                        var ok = l.indexOf("OK ") === 0
                        return { ok: ok, path: l.substring(ok ? 3 : 5) }
                    })
            }
            Qt.callLater(() => { depsSource.disconnectSource(sourceName) })
        }
    }

    Component.onCompleted: refreshDeps()

    // ---------- 操作 ----------
    function refreshStatus() {
        root.oneShotSeq++
        statusSource.connectSource(root.statusCmd + " #s" + root.oneShotSeq)
    }
    function refreshDeps() {
        root.oneShotSeq++
        depsSource.connectSource(root.depsCmd + " #d" + root.oneShotSeq)
    }
    function runCtl(args) {
        if (root.busy || root.awaitingHotspot) { return }
        root.busy = true
        root.lastAction = args
        root.message = i18n("Running: %1", args)
        actionSource.connectSource("pkexec " + root.ctl + " " + args)
    }
    function toggleHotspot() {
        runCtl((root.isOff || !root.hotRunning) ? "on" : "off")
    }
    function setMode(m) {
        if (m !== root.mode) { runCtl("mode " + m) }
    }
    function setAutostart(v) { runCtl("autostart " + (v ? "on" : "off")) }
    // 安全地把值交给 shell（单引号包裹 + 内部单引号转义）
    function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }
    function setCredentials(ssid, pass) {
        if (!ssid || ssid.length === 0) { root.message = i18n("Failed: %1", i18n("Hotspot name cannot be empty")); return }
        if (ssid.length > 32) { root.message = i18n("Failed: %1", i18n("Hotspot name must be at most 32 characters")); return }
        if (pass && pass.length > 0 && (pass.length < 8 || pass.length > 63)) {
            root.message = i18n("Failed: %1", i18n("Password must be 8-63 characters"))
            return
        }
        runCtl("set-credentials " + shq(ssid) + " " + shq(pass ? pass : ""))
    }

    compactRepresentation: CompactRepresentation {}
    fullRepresentation: FullRepresentation {}
}
