import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

Kirigami.FormLayout {
    property alias cfg_showLabel: showLabelBox.checked
    property alias cfg_pollInterval: pollSpin.value

    QQC2.CheckBox {
        id: showLabelBox
        text: i18n("Show band/channel next to the tray icon")
    }

    QQC2.SpinBox {
        id: pollSpin
        from: 2
        to: 60
        Kirigami.FormData.label: i18n("Status refresh interval (seconds)")
    }

    QQC2.Label {
        Kirigami.FormData.isSection: true
        text: i18n("Tip: concurrent mode keeps Wi-Fi connected (the hotspot follows the Wi-Fi channel; it falls back to 2.4GHz if the hardware refuses 5GHz); normal mode disconnects Wi-Fi and uses the whole NIC as the hotspot.")
        wrapMode: Text.WordWrap
        opacity: 0.7
    }
}
