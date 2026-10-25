import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Modules.Plugins

// 常驻守护进程 surface：跟 UI 可见性无关。
// 放在 widget 里的话，只有控制中心打开时 Process 才活着 —— 关掉面板自动旋转就停了。
PluginComponent {
    id: root

    readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")

    Process {
        id: daemonProc
        command: ["python3", root.pluginDir + "scripts/nabu-autorotate.py"]
        running: true
        onExited: (code, status) => {
            if (code !== 0 && code !== 143)   // 143 = SIGTERM（DMS 卸载）
                restartTimer.start()
        }
    }

    Timer {
        id: restartTimer
        interval: 3000
        repeat: false
        onTriggered: daemonProc.running = true
    }

    // 关闭自动旋转时左下角的「点了就转」浮层
    // 直接实例化：daemon surface 本身没有图形场景，LazyLoader 在里面不加载
    RotateHintWindow {
        id: hintWindow
    }
}
