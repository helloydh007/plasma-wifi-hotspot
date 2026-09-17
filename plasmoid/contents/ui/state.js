.pragma library

// 状态机（纯函数）：从后端 status JSON 推导 UI 的 phase / 是否画"关闭"斜线。
//
// 为什么单独放一份 JS 而不是内联在 main.qml：
// 这些判定以前只被 qmllint 做语法检查，语义错了没有测试能发现。2026-09-17 的
// "开机自启进入待命、热点没起来但托盘不画红色斜线" 就是这类 bug。纯函数可以被
// tests/test-ui-state.js 直接用 Node 跑回归。
//
// 注意：QML 绑定只跟踪**传给函数的参数**（st / awaitingHotspot），所以这里不要
// 去读 QML 作用域里的其它属性，否则它们变化时函数返回值不会刷新。

function phaseOf(st, awaitingHotspot) {
    st = st || {}
    if (typeof st.mode !== "string") {
        return "unavailable"
    }

    var mode = st.mode
    // 后端服务的真实状态串（ActiveState/SubState），由 ctl 的 status 给出。
    // 不能只看"服务是不是 active"：Restart=on-failure 的服务在脚本崩溃后会处于
    // activating/auto-restart，此时 systemctl is-active 依然返回 0 —— 面板若据此判断，
    // 就会把"后端已经死了"显示成"已开启"（2026-09-16 实机故障）。
    var backendState = mode === "normal"
        ? (st.normal_service_state || "")
        : (st.concurrent_service_state || "")
    var hotRunning = !!(st.hotspot && st.hotspot.running === "yes")
    var backendAlive = backendState.indexOf("active/running") === 0
    var isOff = st.disabled === true

    if (hotRunning) {
        return "running"
    }
    if (awaitingHotspot) {
        return "starting"
    }
    if (backendState.indexOf("failed") === 0) {
        return "failed"
    }
    if (backendState.indexOf("activating") === 0) {
        return "starting"
    }
    if (isOff) {
        return "off"
    }
    if (backendAlive) {
        return "standby"
    }
    return "off"
}

// 斜线 = "现在没有热点可用"。
// 只有确实在发信标（running）或正在启动（starting）才不画；待命（standby）虽然
// 后端的 systemd 单元活着，但热点并没有发出信标，必须画——否则开机自启后服务进入
// 待命、热点实际没起来时，图标会显示成"已开启"。
function offBadgeOf(phase) {
    return phase !== "running" && phase !== "starting"
}
