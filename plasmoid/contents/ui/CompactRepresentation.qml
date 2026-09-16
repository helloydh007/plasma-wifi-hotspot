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
    // 非受限（横向面板/桌面）时=图标+文字的固有尺寸。
    //
    // 判定依据全部取自官方部件的写法：
    //  - CustomEmbeddedContainment：本部件被嵌进别的 containment（= 系统托盘）。
    //    见 org.kde.plasma.weather 的 needsToBeSquare（它用的就是这两个条件）
    //  - ContainmentForcesSquarePlasmoids：容器强制方形格子
    //  - formFactor === Vertical：竖直面板没有放横向文字的位置。
    //    见 org.kde.plasma.kickoff：“A text label cannot be set when the Panel is vertical”，
    //    以及它的 shouldHaveLabel: formFactor !== Vertical
    // 注意**不能**把 formFactor 的 Horizontal 也算成受限：Horizontal 的含义是
    // “在横向面板里”，而横向面板本来就该显示图标+文字。旧实现照搬了
    // org.kde.plasma.battery 的 isConstrained（[Vertical, Horizontal].includes(formFactor)），
    // 但 battery 那里判的是“只放图标 vs 显示多电池网格视图”，不是文字标签；
    // 照搬的结果是 showLabel=true（默认值）时文字在托盘和面板里都永远不显示
    //（只有把部件拖到桌面上才会出现）。
    readonly property bool isConstrained: Plasmoid.formFactor === PlasmaCore.Types.Vertical
        || (Plasmoid.containmentType & PlasmaCore.Types.CustomEmbeddedContainment)
        || (Plasmoid.containmentDisplayHints & PlasmaCore.Types.ContainmentForcesSquarePlasmoids)

    // 主动声明“我需要方形格子”（仅托盘/被强制方形时），与 weather 部件一致。
    // 横向面板里刻意不声明，否则面板会把我压成方形、文字又没地方放。
    Binding {
        target: Plasmoid
        property: "needsToBeSquare"
        value: (Plasmoid.containmentType & PlasmaCore.Types.CustomEmbeddedContainment)
            | (Plasmoid.containmentDisplayHints & PlasmaCore.Types.ContainmentForcesSquarePlasmoids)
    }

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

        // 热点原图标 + 关闭时的红色斜线（仿托盘静音图标的样式，不变暗）
        Item {
            implicitWidth: compact.iconSize
            implicitHeight: compact.iconSize

            Kirigami.Icon {
                anchors.fill: parent
                source: root.baseIcon
                active: compact.containsMouse
            }
            // Breeze audio-volume-muted 的斜线几何：22px 画布中从 (3,3) 到 (19,19)，
            // 即长 0.983 倍图标尺寸、粗 1/22，45° 居中，不触及四角
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
