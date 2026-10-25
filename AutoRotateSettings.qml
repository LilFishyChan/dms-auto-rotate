import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.DCommon.Widgets as DCommon
import qs.Modules.Plugins

PluginSettings {
    id: settings
    pluginId: "nabuAutoRotate"

    function tr(term) {
        return I18n.trFor("nabuAutoRotate", term);
    }

    // ---- 启动阶段的写入守卫 ----
    // DMS 会在插件数据从磁盘加载之前就预创建设置页；此时每个 Setting 的
    // loadValue() 只能拿到 defaultValue，而 onValueChanged 会立刻把这个默认值
    // 保存回去，把磁盘上的真实设置冲掉（症状：重启 DMS 后设置全变回默认）。
    // 所以在数据就绪之前一律拦住写入，就绪后再统一重读一遍。
    property bool savingEnabled: false

    function saveValue(key, value) {
        if (!settings.savingEnabled)
            return
        if (pluginService && pluginService.savePluginData) {
            pluginService.savePluginData(pluginId, key, value)
            settingChanged()
        }
    }

    Timer {
        interval: 1200
        running: true
        repeat: false
        onTriggered: {
            // 此刻数据已就绪，先把所有控件重读成真实值
            const stack = [settings]
            while (stack.length > 0) {
                const item = stack.pop()
                if (typeof item.loadValue === "function")
                    item.loadValue()
                for (let i = 0; i < item.children.length; i++)
                    stack.push(item.children[i])
            }
            // 之后才允许写入
            settings.savingEnabled = true
        }
    }


    // 真实输出列表，由 niri 动态填充
    property var outputOptions: [{ label: tr("Auto (first output)"), value: "auto" }]

    Component.onCompleted: listOutputs.running = true

    Process {
        id: listOutputs
        command: ["sh", "-c", "niri msg --json outputs 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const d = JSON.parse(text)
                    const opts = [{ label: settings.tr("Auto (first output)"), value: "auto" }]
                    for (const k in d)
                        opts.push({ label: k, value: k })
                    settings.outputOptions = opts
                } catch (e) {
                    console.log("nabuAutoRotate: failed to read output list:", e)
                }
            }
        }
    }


    // 滑块 + 右侧重置图标；只在值偏离默认值时出现
    component ResettableSlider: Column {
        id: rs
        property string settingKey
        property string label
        property string description: ""
        property int defaultValue: 0
        property int minimum: 0
        property int maximum: 100
        property string unit: ""

        width: parent.width
        spacing: 0

        SliderSetting {
            id: slider
            width: rs.width
            settingKey: rs.settingKey
            label: rs.label
            description: rs.description
            defaultValue: rs.defaultValue
            minimum: rs.minimum
            maximum: rs.maximum
            unit: rs.unit
        }

        Item {
            width: rs.width
            height: 20
            visible: slider.value !== rs.defaultValue

            DCommon.DIcon {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                name: "restart_alt"
                size: 15
                color: Theme.primary

                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -6
                    cursorShape: Qt.PointingHandCursor
                    onClicked: slider.value = rs.defaultValue
                }
            }
        }
    }

    StyledText {
        width: parent.width
        text: settings.tr("Toggle it from the control center. Every change takes effect immediately.")
        font.pixelSize: Theme.fontSizeMedium
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    // ================= 显示器 =================
    StyledText {
        width: parent.width
        text: settings.tr("Display")
        font.pixelSize: Theme.fontSizeMedium
        font.bold: true
        color: Theme.surfaceText
        topPadding: Theme.spacingM
    }

    SelectionSetting {
        settingKey: "output"
        label: settings.tr("Bound display")
        description: settings.tr("Which niri output to rotate; with multiple monitors pick the one you want (default: the first)")
        defaultValue: ""
        options: settings.outputOptions
    }

    // ================= 传感器 =================
    StyledText {
        width: parent.width
        text: settings.tr("Sensor")
        font.pixelSize: Theme.fontSizeMedium
        font.bold: true
        color: Theme.surfaceText
        topPadding: Theme.spacingM
    }

    SelectionSetting {
        settingKey: "sensor_backend"
        label: settings.tr("Sensor backend")
        description: settings.tr("Auto picks the first backend that works. Pin it when auto-detection lands on a backend that reports the wrong orientation (common when the firmware mount matrix is all zeros and iio-sensor-proxy falls back to identity).")
        defaultValue: "auto"
        options: [
            { label: settings.tr("Auto-detect"), value: "auto" },
            { label: settings.tr("iio-sensor-proxy"), value: "iio" },
            { label: settings.tr("Qualcomm SSC (ssccli)"), value: "ssccli" },
            { label: settings.tr("sysfs"), value: "sysfs" }
        ]
    }

    // ================= 方向校准 =================
    StyledText {
        width: parent.width
        text: settings.tr("Orientation calibration")
        font.pixelSize: Theme.fontSizeMedium
        font.bold: true
        color: Theme.surfaceText
        topPadding: Theme.spacingM
    }

    StyledText {
        width: parent.width
        text: settings.tr("If a direction comes out mirrored, use these three settings to correct it. The device axes are fixed, so this only needs doing once.")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    ToggleSetting {
        settingKey: "swap_xy"
        label: settings.tr("Swap X / Y axes")
        description: settings.tr("Enable when portrait and landscape detection are swapped as a whole")
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "invert_x"
        label: settings.tr("Invert X axis")
        description: settings.tr("Enable when both landscape directions are mirrored")
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "invert_y"
        label: settings.tr("Invert Y axis")
        description: settings.tr("Enable when upside-down is detected backwards")
        defaultValue: false
    }

    // ================= 行为调整 =================
    StyledText {
        width: parent.width
        text: settings.tr("Behaviour")
        font.pixelSize: Theme.fontSizeMedium
        font.bold: true
        color: Theme.surfaceText
        topPadding: Theme.spacingM
    }

    ResettableSlider {
        settingKey: "debounce_ms"
        label: settings.tr("Debounce")
        description: settings.tr("How long a direction must hold before the screen rotates; too small makes it flicker while turning")
        defaultValue: 700
        minimum: 300
        maximum: 2000
        unit: " ms"
    }

    ResettableSlider {
        settingKey: "dominate_ratio_x10"
        label: settings.tr("Dominant-axis threshold")
        description: settings.tr("How much the main axis must exceed the other before a direction is decided (x0.1); raise it to stop twitching when the device lies at an angle")
        defaultValue: 16
        minimum: 10
        maximum: 30
        unit: " x0.1"
    }

    // ================= 关闭时的提示 =================
    StyledText {
        width: parent.width
        text: settings.tr("When disabled")
        font.pixelSize: Theme.fontSizeMedium
        font.bold: true
        color: Theme.surfaceText
        topPadding: Theme.spacingM
    }

    ToggleSetting {
        settingKey: "show_rotate_hint"
        label: settings.tr("Rotation hint button")
        description: settings.tr("While auto-rotate is off, show a round rotate button in the bottom-left corner whenever the device is turned away from the current screen orientation. Tapping it rotates the screen to match.")
        defaultValue: true
    }
}
