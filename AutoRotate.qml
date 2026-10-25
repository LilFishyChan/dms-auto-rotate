import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    function tr(term) {
        return I18n.trFor("nabuAutoRotate", term);
    }

    // 插件自身目录（Qt.resolvedUrl 带尾斜杠）
    readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")
    readonly property string dmsSettings: Quickshell.env("HOME") + "/.config/dms/plugin_settings.json"

    property bool isEnabled: false

    // 守护进程在 Daemon.qml 的 daemon surface 里常驻，不随控制中心开关而启停。
    // ================= 状态查询 / 切换 =================
    Process {
        id: queryProc
        command: ["python3", "-c",
            "import json;d=json.load(open('" + root.dmsSettings + "'));" +
            "print('on' if d.get('nabuAutoRotate',{}).get('active',True) else 'off')"]
        stdout: SplitParser {
            onRead: line => root.isEnabled = (line.trim() === "on")
        }
    }

    Process {
        id: toggleProc
        command: []
        onExited: queryProc.running = true
    }

    function setEnabled(on) {
        isEnabled = on                        // 立即反馈
        toggleProc.command = ["python3", "-c",
            "import json;p='" + root.dmsSettings + "';d=json.load(open(p));" +
            "d.setdefault('nabuAutoRotate',{})['active']=" + (on ? "True" : "False") + ";" +
            "json.dump(d,open(p,'w'),indent=2)"]
        toggleProc.running = true
    }

    Component.onCompleted: queryProc.running = true

    // ================= 控制中心开关 =================
    ccWidgetIcon: "screen_rotation"
    ccWidgetPrimaryText: tr("Auto Rotate")
    ccWidgetSecondaryText: isEnabled ? tr("On") : tr("Off")
    ccWidgetIsActive: isEnabled

    onCcWidgetToggled: root.setEnabled(!root.isEnabled)

    // ================= 栏内图标 =================
    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingS
            DankIcon {
                name: "screen_rotation"
                size: Theme.iconSize
                color: root.isEnabled ? Theme.primary : Theme.surfaceVariantText
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        DankIcon {
            name: "screen_rotation"
            size: Theme.iconSize
            color: root.isEnabled ? Theme.primary : Theme.surfaceVariantText
            anchors.horizontalCenter: parent.horizontalCenter
        }
    }
}
