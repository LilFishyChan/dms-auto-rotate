import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Widgets

// 自动旋转关闭时的小浮层：设备转了但屏幕没转，左下角出现一个圆形旋转按钮，
// 点一下就把屏幕转到当前设备方向。跟 Android 的做法一样。
PanelWindow {
    id: root

    // 由 daemon 写出来的状态：设备朝向 vs 屏幕朝向
    property bool showHint: true
    property bool active: true
    property bool pending: false
    property string sensorTransform: ""
    property string appliedTransform: ""
    property string output: ""

    readonly property string stateFile: Quickshell.env("HOME") + "/.local/state/nabu-autorotate/state.json"

    // 出现后只停留几秒就自己消失（跟 Android 一样）
    property bool hintActive: false

    readonly property bool shouldShow: showHint && !active && pending && sensorTransform !== ""

    visible: shouldShow && hintActive

    onShouldShowChanged: {
        if (shouldShow) {
            hintActive = true
            hideTimer.restart()
        } else {
            hintActive = false
        }
    }

    Timer {
        id: hideTimer
        interval: 4000
        repeat: false
        onTriggered: root.hintActive = false
    }

    color: "transparent"
    anchors {
        bottom: true
        left: true
    }
    margins {
        bottom: 28
        left: 28
    }
    implicitWidth: 44
    implicitHeight: 44

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.namespace: "nabu-rotate-hint"

    // ── 轮询状态 ──────────────────────────────────────────
    Timer {
        interval: 600
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: stateProc.running = true
    }

    Process {
        id: stateProc
        command: ["python3", "-c",
            "import json,sys\n" +
            "settings='" + Quickshell.env("HOME") + "/.config/dms/plugin_settings.json'\n" +
            "hint=True\n" +
            "try:\n" +
            "  hint=json.load(open(settings)).get('nabuAutoRotate',{}).get('show_rotate_hint',True)\n" +
            "except Exception: pass\n" +
            "try:\n" +
            "  d=json.load(open('" + root.stateFile + "'))\n" +
            "  print(1 if hint else 0, 1 if d.get('active') else 0, 1 if d.get('pending') else 0,\n" +
            "        d.get('sensor_transform',''), d.get('applied_transform',''), d.get('output',''))\n" +
            "except Exception:\n" +
            "  print(1 if hint else 0, '1 0   ')\n"]
        stdout: SplitParser {
            onRead: line => {
                const p = line.trim().split(/\s+/)
                if (p.length >= 3) {
                    // 先更新所有依赖项，pending 最后赋值 —— 否则 onPendingChanged
                    // 会在 sensorTransform 还是旧值时触发，shouldShow 算成 false
                    root.showHint = p[0] === "1"
                    root.active = p[1] === "1"
                    root.sensorTransform = p[3] || ""
                    root.appliedTransform = p[4] || ""
                    root.output = p[5] || ""
                    root.pending = p[2] === "1"
                }
            }
        }
    }

    // ── 圆形按钮 ──────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: hover.containsMouse
               ? Theme.withAlpha(Theme.surfaceContainerHighest, 0.96)
               : Theme.withAlpha(Theme.surfaceContainerHigh, 0.88)
        border.width: 1
        border.color: Theme.withAlpha(Theme.primary, 0.45)

        DankIcon {
            id: icon
            anchors.centerIn: parent
            name: "screen_rotation"
            size: 22
            color: Theme.primary
        }

        HoverHandler {
            id: hover
            cursorShape: Qt.PointingHandCursor
        }

        TapHandler {
            onTapped: {
                if (!root.sensorTransform)
                    return
                root.hintActive = false          // 点了立刻消失，不等计时器
                hideTimer.stop()
                applyProc.command = ["niri", "msg", "output",
                                     root.output || "DSI-1",
                                     "transform", root.sensorTransform]
                applyProc.running = true
            }
        }
    }

    Process {
        id: applyProc
        command: []
        onExited: {
            // 点完立刻刷新，避免按钮在状态文件更新前多留一会儿
            stateProc.running = true
        }
    }
}
