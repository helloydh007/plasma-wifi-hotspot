import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

Kirigami.FormLayout {
    property alias cfg_showLabel: showLabelBox.checked
    property alias cfg_pollInterval: pollSpin.value

    QQC2.CheckBox {
        id: showLabelBox
        text: "在托盘图标旁显示频段/信道"
    }

    QQC2.SpinBox {
        id: pollSpin
        from: 2
        to: 60
        Kirigami.FormData.label: "状态刷新间隔（秒）"
    }

    QQC2.Label {
        Kirigami.FormData.isSection: true
        text: "提示：并发模式保持 Wi-Fi 连接（热点在 2.4GHz 同信道）；普通模式会断开 Wi-Fi，把网卡整体当热点用。"
        wrapMode: Text.WordWrap
        opacity: 0.7
    }
}
