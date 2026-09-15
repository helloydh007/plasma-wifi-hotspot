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
                    text: i18n("Hotspot: %1", root.stateText)
                    font.bold: true
                }
                QQC2.Label {
                    text: root.mode === "normal" ? i18n("Normal mode (Wi-Fi disconnected, NIC as AP)")
                                                 : i18n("Concurrent mode (Wi-Fi stays connected)")
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

            QQC2.Label { text: i18nc("@label wifi row", "Wi-Fi"); opacity: 0.7 }
            QQC2.Label {
                Layout.fillWidth: true
                text: {
                    // 按实际连接状态显示，而不是按模式（普通模式下 Wi-Fi 也可能已连接）
                    var connected = (root.st.wifi && root.st.wifi.connected === "yes")
                    if (!connected) {
                        return root.mode === "normal" ? i18n("Not connected (normal mode occupies the NIC)")
                                                      : i18n("Not connected")
                    }
                    return root.wifiSsid + (root.wifiBand ? "　" + root.wifiBand + (root.wifiCh ? " ch" + root.wifiCh : "") : "")
                }
            }

            QQC2.Label { text: i18n("Hotspot"); opacity: 0.7 }
            QQC2.Label {
                Layout.fillWidth: true
                text: {
                    if (!root.hotRunning) return root.isOff ? i18nc("The hotspot is switched off", "Off") : i18n("Standby (no beacon)")
                    return root.hotspotSsid + "　" + (root.hotBand || "") + (root.hotCh ? " ch" + root.hotCh : "")
                        + (root.clients > 0 ? "　" + i18np("%1 device", "%1 devices", root.clients) : "")
                }
            }

            QQC2.Label { text: i18n("Autostart"); opacity: 0.7 }
            QQC2.Label {
                Layout.fillWidth: true
                text: root.autostartState === "on" ? i18n("Enabled") : i18n("Disabled")
            }
        }

        // ---------- 主开关 ----------
        QQC2.Label {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            visible: root.mode === "normal" && root.isOff
            wrapMode: Text.WordWrap
            text: i18n("⚠ Normal mode: turning on the hotspot disconnects the current Wi-Fi (uplink then relies on wired network)")
            font.pointSize: Kirigami.Theme.smallFont.pointSize
        }

        QQC2.Button {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            enabled: !root.busy && root.ready
            text: root.busy ? i18n("Running…") : ((root.isOff || !root.hotRunning) ? i18n("Turn on hotspot") : i18n("Turn off hotspot"))
            icon.name: (root.isOff || !root.hotRunning) ? "network-wireless-hotspot" : "dialog-cancel"
            onClicked: root.toggleHotspot()
        }

        Kirigami.Separator { Layout.fillWidth: true }

        // ---------- 模式 ----------
        QQC2.Label {
            Layout.leftMargin: Kirigami.Units.smallSpacing
            text: i18n("Hotspot mode")
            opacity: 0.7
            font.pointSize: Kirigami.Theme.smallFont.pointSize
        }
        QQC2.RadioButton {
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.fillWidth: true
            text: i18n("Concurrent (Wi-Fi stays on, hotspot limited to 2.4GHz same channel)")
            checked: root.mode === "concurrent"
            enabled: !root.busy
            onClicked: root.setMode("concurrent")
        }
        QQC2.RadioButton {
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.fillWidth: true
            text: i18n("Normal (disconnect Wi-Fi, whole NIC as hotspot)")
            checked: root.mode === "normal"
            enabled: !root.busy
            onClicked: root.setMode("normal")
        }

        QQC2.CheckBox {
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.fillWidth: true
            text: i18n("Autostart hotspot at boot")
            enabled: !root.busy
            checked: root.autostartState === "on"
            onClicked: root.setAutostart(checked)
        }

        Kirigami.Separator { Layout.fillWidth: true }

        // ---------- 热点名称 / 密码 ----------
        QQC2.Label {
            Layout.leftMargin: Kirigami.Units.smallSpacing
            text: i18n("Hotspot name & password")
            opacity: 0.7
            font.pointSize: Kirigami.Theme.smallFont.pointSize
        }
        // 当前热点密码：默认打码，点眼睛图标显示/隐藏
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            QQC2.Label { text: i18n("Current password"); opacity: 0.7 }
            QQC2.Label {
                Layout.fillWidth: true
                text: root.showPass ? (root.hotspotPass.length > 0 ? root.hotspotPass : i18n("(not set)"))
                                    : "••••••••"
                wrapMode: Text.WrapAnywhere
            }
            QQC2.ToolButton {
                Accessible.name: root.showPass ? i18n("Hide password") : i18n("Show password")
                icon.name: root.showPass ? "password-show-on" : "password-show-off"
                onClicked: root.showPass = !root.showPass
            }
        }
        QQC2.TextField {
            id: ssidField
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            placeholderText: i18n("Hotspot name (1-32 characters)")
            text: root.hotspotSsid
            enabled: !root.busy
        }
        QQC2.TextField {
            id: passField
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            placeholderText: i18n("New password (8-63 characters, empty = keep password)")
            echoMode: TextInput.Password
            enabled: !root.busy
        }
        QQC2.Button {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            enabled: !root.busy
            text: i18n("Apply name/password")
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
            text: i18n("When the hotspot is running it restarts automatically to apply the change (connected devices must reconnect).")
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
                    ? i18n("Dependencies: all ready ✓")
                    : i18n("Dependencies: %1 missing ⚠", root.missingDeps.length)
                font.bold: root.missingDeps.length > 0
            }
            QQC2.Button {
                text: i18n("Recheck")
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
                text: i18n("Fix commands (one auth prompt; package installs are deliberately not password-free)")
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
                text: i18n("Copy commands")
                icon.name: "edit-copy"
                onClicked: {
                    fixField.selectAll()
                    fixField.copy()
                    root.message = i18n("Commands copied to clipboard")
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
