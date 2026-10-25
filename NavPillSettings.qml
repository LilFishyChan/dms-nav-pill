import QtQuick
import qs.Common
import qs.Widgets
import qs.DCommon.Widgets as DCommon
import qs.Modules.Plugins

PluginSettings {
    id: settings
    pluginId: "nabuNavPill"

    function tr(term) {
        return I18n.trFor("nabuNavPill", term);
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

    // 动作表：value 必须和 NavPill.qml 的 ACTIONS 键一致。
    // "hide" 是内部动作（收回横条），其余走命令表。
    readonly property var actionOptions: [
        {label: tr("None"), value: "none"},
        {label: tr("Hide the pill"), value: "hide"},
        {label: tr("Toggle overview"), value: "toggle-overview"},
        {label: tr("Open overview"), value: "open-overview"},
        {label: tr("Close overview"), value: "close-overview"},
        {label: tr("Focus column left"), value: "niri-focus-left"},
        {label: tr("Focus column right"), value: "niri-focus-right"},
        {label: tr("Focus window up"), value: "niri-focus-up"},
        {label: tr("Focus window down"), value: "niri-focus-down"},
        {label: tr("Move column left"), value: "niri-move-left"},
        {label: tr("Move column right"), value: "niri-move-right"},
        {label: tr("Close window"), value: "niri-close"},
        {label: tr("Toggle fullscreen"), value: "niri-fullscreen"},
        {label: tr("Toggle floating"), value: "niri-float"},
        {label: tr("Workspace up"), value: "niri-ws-up"},
        {label: tr("Workspace down"), value: "niri-ws-down"},
        {label: tr("Control center"), value: "control-center"},
        {label: tr("Launcher"), value: "launcher"},
        {label: tr("Notifications"), value: "notifications"},
        {label: tr("Power menu"), value: "powermenu"},
        {label: tr("Clipboard"), value: "clipboard"},
        {label: tr("Dashboard"), value: "dms-dash"},
        {label: tr("Volume up"), value: "dms-vol-up"},
        {label: tr("Volume down"), value: "dms-vol-down"},
        {label: tr("Mute"), value: "dms-mute"},
        {label: tr("Brightness up"), value: "dms-bri-up"},
        {label: tr("Brightness down"), value: "dms-bri-down"},
        {label: tr("Custom command"), value: "custom"}
    ]

    // 滑块 + 下方重置图标；只在值偏离默认时才显示图标
    component ResettableSlider: Column {
        id: rs
        property string settingKey
        property string label
        property string description: ""
        property int defaultValue: 0
        property int minimum: 0
        property int maximum: 100
        property string unit: ""
        property int step: 1

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

            Timer {
                interval: 1000
                running: true
                repeat: false
                onTriggered: slider.loadValue()
            }

            // SliderSetting 没暴露 step，注入给内部 DSlider
            Component.onCompleted: {
                if (rs.step <= 1) return
                for (let i = 0; i < children.length; i++) {
                    if (children[i].step !== undefined) {
                        children[i].step = rs.step
                        break
                    }
                }
            }
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

    // 一行手势：左边名字，右边动作下拉；选到自定义才多出命令框
    component GestureRow: Column {
        id: gestureRow
        property string settingKey
        property string title
        property string defaultAction: "none"

        width: parent.width
        spacing: Theme.spacingS

        Row {
            width: gestureRow.width
            spacing: Theme.spacingM

            StyledText {
                id: gestureLabel
                readonly property real labelWidth: Math.round((gestureRow.width - Theme.spacingM) * 0.42)
                width: labelWidth
                height: sel.implicitHeight
                text: gestureRow.title
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceText
                wrapMode: Text.WordWrap
                verticalAlignment: Text.AlignVCenter
            }

            SelectionSetting {
                id: sel
                width: gestureRow.width - Theme.spacingM - gestureLabel.labelWidth
                settingKey: gestureRow.settingKey
                label: ""
                options: settings.actionOptions
                defaultValue: gestureRow.defaultAction

                // DMS 会在插件数据加载之前就预创建设置页，那时 loadValue()
                // 只能拿到 defaultValue，随后 onValueChanged 会把默认值写回去。
                // 等数据就绪后重新读一次。
                Timer {
                    interval: 1000
                    running: true
                    repeat: false
                    onTriggered: sel.loadValue()
                }
            }
        }

        StringSetting {
            id: customCmd
            visible: sel.value === "custom"
            height: visible ? implicitHeight : 0
            settingKey: "custom_" + gestureRow.settingKey
            label: settings.tr("Custom command")
            description: ""
            placeholder: "niri msg action toggle-overview"
            defaultValue: ""

            Timer {
                interval: 1000
                running: true
                repeat: false
                onTriggered: customCmd.loadValue()
            }
        }
    }

    StyledText {
        width: parent.width
        text: tr("Android-style gesture bar. Hidden while windows are open; swipe up from the bottom edge to bring it back.")
        font.pixelSize: Theme.fontSizeMedium
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    // ---------- 唤出手势 ----------
    StyledText {
        width: parent.width
        text: tr("Swipe-to-reveal")
        font.pixelSize: Theme.fontSizeMedium
        font.bold: true
        color: Theme.surfaceText
        topPadding: Theme.spacingL
    }

    ResettableSlider {
        settingKey: "bottom_band_px"
        label: tr("Bottom band")
        description: tr("Height of the swipe-reveal zone in pixels. Never smaller than pill height + 2× bottom margin.")
        defaultValue: 40
        minimum: 20
        maximum: 300
        unit: " px"
    }

    ResettableSlider {
        settingKey: "swipe_min_pct"
        label: tr("Minimum swipe distance")
        description: tr("Upward travel required, as a percentage of screen height")
        defaultValue: 5
        minimum: 2
        maximum: 30
        unit: "%"
    }

    ResettableSlider {
        settingKey: "vertical_bias_x10"
        label: tr("Vertical bias")
        description: tr("How much more vertical than horizontal the swipe must be (x0.1)")
        defaultValue: 11
        minimum: 5
        maximum: 40
    }

    ResettableSlider {
        settingKey: "cooldown_ms"
        label: tr("Cooldown")
        description: tr("Ignore further reveals for this long after one fires")
        defaultValue: 1114
        minimum: 300
        maximum: 5000
        unit: " ms"
    }

    // ---------- 横条外观 ----------
    StyledText {
        width: parent.width
        text: tr("Pill appearance")
        font.pixelSize: Theme.fontSizeMedium
        font.bold: true
        color: Theme.surfaceText
        topPadding: Theme.spacingL
    }

    ResettableSlider {
        settingKey: "pill_width"
        label: tr("Width")
        defaultValue: 172
        minimum: 80
        maximum: 400
        unit: " px"
    }

    ResettableSlider {
        settingKey: "pill_height"
        label: tr("Height")
        defaultValue: 6
        minimum: 2
        maximum: 12
        unit: " px"
    }

    ResettableSlider {
        settingKey: "pill_margin"
        label: tr("Distance from bottom")
        defaultValue: 6
        minimum: 0
        maximum: 40
        unit: " px"
    }

    ResettableSlider {
        settingKey: "pill_opacity_pct"
        label: tr("Opacity")
        defaultValue: 75
        minimum: 10
        maximum: 100
        unit: "%"
    }

    // ---------- 行为 ----------
    StyledText {
        width: parent.width
        text: tr("Behaviour")
        font.pixelSize: Theme.fontSizeMedium
        font.bold: true
        color: Theme.surfaceText
        topPadding: Theme.spacingL
    }

    ResettableSlider {
        settingKey: "reveal_hold_ms"
        label: tr("Auto-hide delay")
        description: tr("How long the revealed pill stays before fading out")
        defaultValue: 3000
        minimum: 1000
        maximum: 10000
        step: 100
        unit: " ms"
    }

    // ---------- 手势动作 ----------
    StyledText {
        width: parent.width
        text: tr("Pill gestures")
        font.pixelSize: Theme.fontSizeMedium
        font.bold: true
        color: Theme.surfaceText
        topPadding: Theme.spacingL
    }

    StyledText {
        width: parent.width
        text: tr("Actions run only while the pill is visible. Revealing it never triggers an action.")
        font.pixelSize: Theme.fontSizeMedium
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    GestureRow {
        settingKey: "action_swipe_up";    title: tr("Swipe up");    defaultAction: "toggle-overview"
    }
    GestureRow {
        settingKey: "action_swipe_down";  title: tr("Swipe down");  defaultAction: "none"
    }
    GestureRow {
        settingKey: "action_swipe_left";  title: tr("Swipe left");  defaultAction: "none"
    }
    GestureRow {
        settingKey: "action_swipe_right"; title: tr("Swipe right"); defaultAction: "none"
    }
    GestureRow {
        settingKey: "action_tap";         title: tr("Tap");         defaultAction: "hide"
    }
    GestureRow {
        settingKey: "action_long_press";  title: tr("Long press");  defaultAction: "none"
    }
}
