import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.plasmoid
import org.kde.kirigami as Kirigami

QQC2.ScrollView {
    id: view
    implicitWidth: Kirigami.Units.gridUnit * 22
    implicitHeight: Kirigami.Units.gridUnit * 26
    clip: true
    contentWidth: availableWidth

    ColumnLayout {
        width: view.availableWidth
        spacing: Kirigami.Units.smallSpacing

        // ---------- 标题 / 状态 ----------
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            // 与托盘一致：热点原图标，关闭时加红色斜线（仿静音图标）
            Item {
                implicitWidth: Kirigami.Units.iconSizes.medium
                implicitHeight: Kirigami.Units.iconSizes.medium
                Kirigami.Icon {
                    anchors.fill: parent
                    source: root.baseIcon
                }
                Rectangle {
                    visible: root.offBadge
                    anchors.centerIn: parent
                    width: parent.width * 0.983
                    height: Math.max(1, parent.width * 0.0455)
                    radius: height / 2
                    rotation: 45
                    color: Kirigami.Theme.negativeTextColor
                }
            }
            ColumnLayout {
                spacing: 0
                Layout.fillWidth: true
                QQC2.Label {
                    text: "热点：" + root.stateText
                    font.bold: true
                }
                QQC2.Label {
                    text: root.mode === "normal" ? "普通模式（断开 Wi-Fi，网卡当 AP）" : "并发模式（保持 Wi-Fi 连接）"
                    opacity: 0.7
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                }
            }
        }

        Kirigami.Separator { Layout.fillWidth: true }

        // ---------- 详情 ----------
        GridLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            columns: 2
            columnSpacing: Kirigami.Units.smallSpacing
            rowSpacing: Kirigami.Units.smallSpacing

            QQC2.Label { text: "Wi-Fi"; opacity: 0.7 }
            QQC2.Label {
                Layout.fillWidth: true
                text: {
                    // 按实际连接状态显示，而不是按模式（普通模式下 Wi-Fi 也可能已连接）
                    var connected = (root.st.wifi && root.st.wifi.connected === "yes")
                    if (!connected) {
                        return root.mode === "normal" ? "未连接（普通模式占用网卡时需断开）" : "未连接"
                    }
                    return root.wifiSsid + (root.wifiBand ? "　" + root.wifiBand + (root.wifiCh ? " ch" + root.wifiCh : "") : "")
                }
            }

            QQC2.Label { text: "热点"; opacity: 0.7 }
            QQC2.Label {
                Layout.fillWidth: true
                text: {
                    if (!root.hotRunning) return root.isOff ? "已关闭" : "待命（未发信标）"
                    return root.hotspotSsid + "　" + (root.hotBand || "") + (root.hotCh ? " ch" + root.hotCh : "")
                        + (root.clients > 0 ? "　" + root.clients + " 台设备" : "")
                }
            }

            QQC2.Label { text: "开机自启"; opacity: 0.7 }
            QQC2.Label {
                Layout.fillWidth: true
                text: root.autostartState === "on" ? "已启用" : "已禁用"
            }
        }

        // ---------- 主开关 ----------
        QQC2.Label {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            visible: root.mode === "normal" && root.isOff
            wrapMode: Text.WordWrap
            text: "⚠ 普通模式：开启热点会断开当前 Wi-Fi 连接（此后设备上网依赖有线网络）"
            font.pointSize: Kirigami.Theme.smallFont.pointSize
        }

        QQC2.Button {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            enabled: !root.busy && root.ready
            text: root.busy ? "执行中…" : ((root.isOff || !root.hotRunning) ? "开启热点" : "关闭热点")
            icon.name: (root.isOff || !root.hotRunning) ? "network-wireless-hotspot" : "dialog-cancel"
            onClicked: root.toggleHotspot()
        }

        Kirigami.Separator { Layout.fillWidth: true }

        // ---------- 模式 ----------
        QQC2.Label {
            Layout.leftMargin: Kirigami.Units.smallSpacing
            text: "热点模式"
            opacity: 0.7
            font.pointSize: Kirigami.Theme.smallFont.pointSize
        }
        QQC2.RadioButton {
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.fillWidth: true
            text: "并发模式（Wi-Fi 不断，热点限 2.4GHz 同信道）"
            checked: root.mode === "concurrent"
            enabled: !root.busy
            onClicked: root.setMode("concurrent")
        }
        QQC2.RadioButton {
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.fillWidth: true
            text: "普通模式（断开 Wi-Fi，网卡整体做热点）"
            checked: root.mode === "normal"
            enabled: !root.busy
            onClicked: root.setMode("normal")
        }

        QQC2.CheckBox {
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.fillWidth: true
            text: "开机自动启用热点"
            enabled: !root.busy
            checked: root.autostartState === "on"
            onClicked: root.setAutostart(checked)
        }

        Kirigami.Separator { Layout.fillWidth: true }

        // ---------- 热点名称 / 密码 ----------
        QQC2.Label {
            Layout.leftMargin: Kirigami.Units.smallSpacing
            text: "热点名称与密码"
            opacity: 0.7
            font.pointSize: Kirigami.Theme.smallFont.pointSize
        }
        // 当前热点密码：默认打码，点眼睛图标显示/隐藏
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            QQC2.Label { text: "当前密码"; opacity: 0.7 }
            QQC2.Label {
                Layout.fillWidth: true
                text: root.showPass ? (root.hotspotPass.length > 0 ? root.hotspotPass : "（未设置）")
                                    : "••••••••"
                wrapMode: Text.WrapAnywhere
            }
            QQC2.ToolButton {
                Accessible.name: root.showPass ? "隐藏密码" : "显示密码"
                icon.name: root.showPass ? "password-show-on" : "password-show-off"
                onClicked: root.showPass = !root.showPass
            }
        }
        QQC2.TextField {
            id: ssidField
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            placeholderText: "热点名称（1-32 字符）"
            text: root.hotspotSsid
            enabled: !root.busy
        }
        QQC2.TextField {
            id: passField
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            placeholderText: "新密码（8-63 字符，留空则只改名称）"
            echoMode: TextInput.Password
            enabled: !root.busy
        }
        QQC2.Button {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            enabled: !root.busy
            text: "应用名称/密码"
            icon.name: "dialog-ok-apply"
            onClicked: {
                root.setCredentials(ssidField.text, passField.text)
                passField.text = ""
            }
        }
        QQC2.Label {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            wrapMode: Text.WordWrap
            opacity: 0.6
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            text: "热点正在运行时，保存后会自动重启热点让新名称/密码生效（已连接的设备需要重连）。"
        }

        Kirigami.Separator { Layout.fillWidth: true }

        // ---------- 依赖自检 ----------
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            QQC2.Label {
                Layout.fillWidth: true
                text: root.missingDeps.length === 0
                    ? "依赖检查：全部就绪 ✓"
                    : ("依赖检查：缺少 " + root.missingDeps.length + " 项 ⚠")
                font.bold: root.missingDeps.length > 0
            }
            QQC2.Button {
                text: "重新检查"
                icon.name: "view-refresh"
                onClicked: root.refreshDeps()
            }
        }

        Repeater {
            model: root.missingDeps
            delegate: QQC2.Label {
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing * 2
                text: "✗ " + modelData.path
                color: Kirigami.Theme.negativeTextColor
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
        }

        // 缺失时的修复入口
        ColumnLayout {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing
            visible: root.missingDeps.length > 0

            QQC2.Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                text: "修复命令（会弹一次授权框；系统包安装刻意不纳入免密授权）"
            }
            QQC2.TextField {
                Layout.fillWidth: true
                readOnly: true
                selectByMouse: true
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                text: {
                    var cmds = []
                    if (root.missingPkgs.length > 0)
                        cmds.push("pkexec apt-get install -y " + root.missingPkgs.join(" "))
                    if (root.backendMissing)
                        cmds.push("pkexec bash " + root.backendDir)
                    if (cmds.length === 0) cmds.push("pkexec bash " + root.backendDir)
                    return cmds.join(" && ")
                }
            }
            QQC2.Button {
                Layout.fillWidth: true
                text: "复制上面的命令"
                icon.name: "edit-copy"
                onClicked: {
                    fixField.selectAll()
                    fixField.copy()
                    root.message = "命令已复制到剪贴板"
                }
            }
        }

        // ---------- 消息 ----------
        QQC2.Label {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            Layout.bottomMargin: Kirigami.Units.smallSpacing
            visible: root.message.length > 0
            wrapMode: Text.WordWrap
            opacity: 0.8
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            text: root.message
        }

        // 供“复制命令”使用（不显示）
        QQC2.TextField {
            id: fixField
            visible: false
            text: {
                var cmds = []
                if (root.missingPkgs.length > 0)
                    cmds.push("pkexec apt-get install -y " + root.missingPkgs.join(" "))
                if (root.backendMissing || cmds.length === 0)
                    cmds.push("pkexec bash " + root.backendDir)
                return cmds.join(" && ")
            }
        }
    }
}
