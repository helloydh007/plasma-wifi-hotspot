import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

MouseArea {
    id: compact

    // 托盘/受限场景：官方托盘给的是方形格子，只能放图标。
    // 这里显式给出尺寸：受限时=图标方形（避免带文字溢出盖住相邻图标），
    // 非受限（放到面板上）时=图标+文字的固有尺寸。
    readonly property bool isConstrained: [PlasmaCore.Types.Vertical, PlasmaCore.Types.Horizontal].includes(Plasmoid.formFactor)
        || (Plasmoid.containmentDisplayHints & PlasmaCore.Types.ContainmentForcesSquarePlasmoids)

    readonly property real iconSize: Kirigami.Units.iconSizes.smallMedium

    hoverEnabled: true
    activeFocusOnTab: true
    implicitWidth: isConstrained ? iconSize : (layout.implicitWidth > 0 ? layout.implicitWidth : iconSize)
    implicitHeight: isConstrained ? iconSize : (layout.implicitHeight > 0 ? layout.implicitHeight : iconSize)
    Accessible.name: Plasmoid.title
    Accessible.role: Accessible.Button
    onClicked: root.expanded = !root.expanded

    RowLayout {
        id: layout
        anchors.centerIn: parent
        spacing: Kirigami.Units.smallSpacing

        // 热点图标 + 关闭时的红色 ✕ 徽标（托盘格子小，徽标画在图标右下角）
        Item {
            implicitWidth: compact.iconSize
            implicitHeight: compact.iconSize

            Kirigami.Icon {
                anchors.fill: parent
                source: root.baseIcon
                active: compact.containsMouse
                opacity: root.offBadge ? 0.4 : 1.0
            }
            Kirigami.Icon {
                visible: root.offBadge
                source: "data-error"
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                implicitWidth: Math.round(parent.width * 0.55)
                implicitHeight: Math.round(parent.height * 0.55)
            }
        }

        // 只在非受限场景（比如放到面板上而非托盘里）显示文字
        PlasmaComponents.Label {
            visible: !compact.isConstrained
                && Plasmoid.configuration.showLabel
                && root.labelText.length > 0
            text: root.labelText
            font.pointSize: Kirigami.Theme.smallFont.pointSize
        }
    }
}
