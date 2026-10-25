import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Widgets
import qs.DCommon.Widgets as DCommon

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

    // 基准角是"设备竖着时"的角。屏幕转了之后，物理上的同一个角会跑到屏幕
    // 的另一边，所以按 appliedTransform 换角 —— 浮窗始终贴在设备的固定角落，
    // 不会跟着画面转来转去。
    property string baseCorner: "bottom-left"
    property bool followRotation: true

    readonly property string corner: {
        // 顺时针排列：左下 → 左上 → 右上 → 右下
        const order = ["bottom-left", "top-left", "top-right", "bottom-right"]
        let i = order.indexOf(baseCorner)
        if (i < 0)
            i = 0
        // 不跟随：固定用屏幕坐标的角落（转屏后它就在画面里换个位置）
        if (!followRotation)
            return order[i]
        if (appliedTransform === "90")
            i = (i + 1) % 4
        else if (appliedTransform === "180")
            i = (i + 2) % 4
        else if (appliedTransform === "270")
            i = (i + 3) % 4
        return order[i]
    }

    anchors.bottom: corner.indexOf("bottom") >= 0
    anchors.top: corner.indexOf("top") >= 0
    anchors.left: corner.indexOf("left") >= 0
    anchors.right: corner.indexOf("right") >= 0
    margins.bottom: 28
    margins.top: 28
    margins.left: 28
    margins.right: 28
    implicitWidth: 44
    implicitHeight: 44

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.namespace: "nabu-rotate-hint"
    // -1 = 忽略其他 surface 预留的区域，锚到真正的屏幕边缘（否则会被顶部栏
    // 或底部 dock 挤开，看起来就"不在角落"）
    WlrLayershell.exclusiveZone: -1

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
            "corner='bottom-left'\n" +
            "follow=True\n" +
            "try:\n" +
            "  _c=json.load(open(settings)).get('nabuAutoRotate',{})\n" +
            "  hint=_c.get('show_rotate_hint',True)\n" +
            "  corner=_c.get('hint_corner','bottom-left')\n" +
            "  follow=_c.get('hint_follow_rotation',True)\n" +
            "except Exception: pass\n" +
            "try:\n" +
            "  d=json.load(open('" + root.stateFile + "'))\n" +
            "  print(1 if hint else 0, 1 if d.get('active') else 0, 1 if d.get('pending') else 0,\n" +
            "        d.get('sensor_transform',''), d.get('applied_transform',''), d.get('output',''), corner, 1 if follow else 0)\n" +
            "except Exception:\n" +
            "  print(1 if hint else 0, '1 0   ', corner, 1 if follow else 0)\n"]
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
                    root.baseCorner = p[6] || "bottom-left"
                    root.followRotation = p[7] !== "0"
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

        DCommon.DIcon {
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
