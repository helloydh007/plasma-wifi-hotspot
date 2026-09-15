import QtQuick
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support

PlasmoidItem {
    id: root

    // 后端控制入口（polkit 规则已授权免密码）
    readonly property string ctl: "/usr/local/sbin/zcode-hotspot-ctl"

    // 状态
    property var st: ({})
    property var deps: []
    property bool busy: false
    property string message: ""

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

    readonly property string stateText: !ready ? "后端不可用" : (isOff ? "已关闭" : (hotRunning ? "运行中" : "待命"))
    readonly property string bandText: hotRunning
        ? ((hotBand || "2.4G") + (hotCh ? " ch" + hotCh : ""))
        : (wifiBand ? (wifiBand + (wifiCh ? " ch" + wifiCh : "")) : "")
    readonly property string labelText: isOff ? "关" : ((mode === "normal" ? "AP " : "") + bandText)

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
        var f = ["/usr/local/sbin/zcode-hotspot-ctl", "/usr/local/sbin/zcode-hotspot.sh",
                 "/etc/systemd/system/zcode-hotspot.service"]
        for (var i = 0; i < f.length; i++) {
            for (var j = 0; j < missingDeps.length; j++) if (missingDeps[j].path === f[i]) return true
        }
        return false
    }
    readonly property string backendDir: Qt.resolvedUrl("../backend/deploy.sh").toString().replace("file://", "")

    // 用热点图标而不是普通无线图标，避免和官方网络图标混淆
    Plasmoid.icon: (!ready || isOff) ? "network-wireless-disconnected" : "network-wireless-hotspot"
    Plasmoid.title: "Wi-Fi 热点控制"
    Plasmoid.status: PlasmaCore.Types.ActiveStatus
    // 托盘里只显示图标，所以把频段/信道放进悬浮提示
    toolTipMainText: "Wi-Fi 热点：" + stateText
    toolTipSubText: hotRunning
        ? ("热点 " + hotspotSsid + "　" + (hotBand || "") + (hotCh ? " ch" + hotCh : "")
           + (clients > 0 ? "　" + clients + " 台设备" : ""))
        : (mode === "normal"
            ? "普通模式：开启会断开 Wi-Fi"
            : (wifiSsid ? ("Wi-Fi " + wifiSsid + "　" + wifiBand + (wifiCh ? " ch" + wifiCh : "")) : "Wi-Fi 未连接"))

    // ---------- 命令 ----------
    readonly property string statusCmd: "pkexec " + ctl + " status"
    readonly property var depsPaths: [
        "/usr/sbin/hostapd",
        "/usr/sbin/dnsmasq",
        "/usr/sbin/iw",
        "/usr/sbin/iptables",
        "/usr/local/sbin/zcode-hotspot.sh",
        "/usr/local/sbin/zcode-hotspot-ctl",
        "/etc/zcode-hotspot/config",
        "/etc/zcode-hotspot/dnsmasq.conf",
        "/etc/systemd/system/zcode-hotspot.service",
        "/etc/systemd/system/zcode-hotspot-dhcp.service",
        "/usr/share/polkit-1/actions/org.zcode.hotspotctl.policy",
        "/etc/NetworkManager/conf.d/99-zcode-hotspot-ap0.conf"
    ]
    readonly property string depsCmd: "sh -c 'for p in " + depsPaths.join(" ")
        + "; do if [ -e $p ]; then echo OK $p; else echo MISS $p; fi; done; "
        + "if pkcheck --action-id org.zcode.hotspotctl.run --process $$ >/dev/null 2>&1; "
        + "then echo OK polkit-免密授权; else echo MISS polkit-免密授权; fi'"

    // ---------- 数据源 ----------
    P5Support.DataSource {
        id: statusSource
        engine: "executable"
        connectedSources: [root.statusCmd]
        onNewData: (sourceName, data) => {
            if (sourceName !== root.statusCmd) { return }
            if (data.stdout && data.stdout.length > 0) {
                try { root.st = JSON.parse(data.stdout) }
                catch (e) { root.st = ({}) }
            } else {
                root.st = ({})
            }
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
                    || (ok ? "已完成" : "见 journalctl -u zcode-hotspot")
            }
            root.message = (ok ? "" : "失败：") + msg
            Qt.callLater(() => { actionSource.disconnectSource(sourceName) })
            root.refreshStatus()
        }
    }

    P5Support.DataSource {
        id: depsSource
        engine: "executable"
        connectedSources: [root.depsCmd]
        onNewData: (sourceName, data) => {
            if (!data.stdout) { root.deps = []; return }
            root.deps = data.stdout.trim().split("\n").filter(function (l) { return l.length > 0 })
                .map(function (l) {
                    var ok = l.indexOf("OK ") === 0
                    return { ok: ok, path: l.substring(ok ? 3 : 5) }
                })
        }
    }

    Timer {
        interval: Math.max(2, Plasmoid.configuration.pollInterval) * 1000
        running: true
        repeat: true
        onTriggered: root.refreshStatus()
    }

    // ---------- 操作 ----------
    function refreshStatus() {
        statusSource.disconnectSource(root.statusCmd)
        statusSource.connectSource(root.statusCmd)
    }
    function refreshDeps() {
        depsSource.disconnectSource(root.depsCmd)
        depsSource.connectSource(root.depsCmd)
    }
    function runCtl(args) {
        if (root.busy) { return }
        root.busy = true
        root.message = "执行中：" + args
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
        if (!ssid || ssid.length === 0) { root.message = "失败：热点名称不能为空"; return }
        if (ssid.length > 32) { root.message = "失败：热点名称最长 32 个字符"; return }
        if (pass && pass.length > 0 && (pass.length < 8 || pass.length > 63)) {
            root.message = "失败：密码长度需 8-63 位"
            return
        }
        runCtl("set-credentials " + shq(ssid) + " " + shq(pass ? pass : ""))
    }

    compactRepresentation: CompactRepresentation {}
    fullRepresentation: FullRepresentation {}
}
