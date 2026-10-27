import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common

// 安卓式底部导航横条
//
// 显示规则
//   没有窗口      → 常显
//   有窗口        → 避让（surface 销毁，触摸透传给下面的应用）
//   底部上滑      → 唤出；唤出后停留 N 秒，无操作再收回（手指按住期间停表）
//   修改设置      → 强制唤出 + 显示感应区，方便看效果
//
// 手势（仅显示时）：上/下/左/右滑、点击、长按，动作在设置页配置
// 拖动曲线：跟手比例 0.75→0.1 线性衰减（积分后单调递增），封顶后不再增长
ShellRoot {
    PanelWindow {
        id: root

        // ==================== 外观配置（plugin_settings.json） ====================
        property int pillWidth: 172
        property int pillHeight: 6
        property int pillMargin: 6
        property real pillOpacity: 0.75
        property int revealHoldMs: 3000
        property int bottomBandPx: 40

        // ==================== 派生尺寸 ====================
        // 感应区最小高度 = 条高 + 上下边距
        readonly property int bandMin: pillHeight + pillMargin * 2
        readonly property int bandHeight: Math.max(bandMin, bottomBandPx)

        // ==================== 动画参数 ====================
        readonly property int fadeMs: 300          // 显示/收起的透明度渐变时长
        readonly property int returnMs: 220        // 松手回位时长

        // ==================== 拖动参数 ====================
        readonly property real dragRatio: 0.2          // 拖动位移 = 手指位移的 1/5
        readonly property real dragLimit: pillHeight   // 位移封顶 = 条高
        readonly property int swipeThreshold: 30           // 松手判定手势的最小位移

        // ==================== 运行状态 ====================
        property bool revealed: false      // 被唤出（避让状态下的临时显示）
        property bool hasWindows: false    // niri 当前有窗口
        property bool shown: false         // surface 是否创建
        property real fadeOpacity: 0       // 独立透明度，先淡出再销毁 surface
        property double lastActionTime: 0  // 上次触发动作的时刻，用于去重

        readonly property bool shouldShow: revealed || !hasWindows

        property var actionMap: ({})       // 手势 → 动作键
        property var customMap: ({})       // 手势 → 自定义命令
        property string lastConfigRaw: ""   // 上一份配置原文，用于检测"设置变了"

        // ==================== 窗口 ====================
        visible: shown
        anchors.bottom: true
        margins.bottom: 0
        implicitWidth: Math.max(320, pillWidth + 120)
        implicitHeight: bandHeight
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "nabu-nav-pill"
        /*
         * -1 = 完全忽略其他 surface 的 exclusive zone，锚在真实屏幕边缘。
         *
         * 0 只是"自己不预留空间"，但仍会被别人预留的区域挤开 —— 虚拟键盘
         * 弹出时就把可用区域缩短，导航条跟着被顶到键盘上方去。改成 -1 后
         * 它钉死在屏幕物理底边，键盘只会盖在上面（Overlay 层在键盘之上）。
         */
        WlrLayershell.exclusiveZone: -1

        // ==================== 工具函数 ====================
        function reveal() {
            root.revealed = true
            hideTimer.restart()
        }

        function pillColor(alpha) {
            return Theme.withAlpha(Theme.primary, alpha)
        }

        // ==================== 内容 ====================
        Item {
            anchors.fill: parent
            opacity: root.fadeOpacity
            Behavior on opacity {
                NumberAnimation { duration: root.fadeMs; easing.type: Easing.InOutQuad }
            }

            // 感应区示意：平时透明，调设置时短暂显示
            Rectangle {
                id: sensorZone
                anchors.fill: parent
                color: Theme.withAlpha(Theme.primary, 0.10)
                border.width: 1
                border.color: Theme.withAlpha(Theme.primary, 0.45)
                opacity: 0
                Behavior on opacity { NumberAnimation { duration: 180 } }
            }

            Rectangle {
                id: pill
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: root.pillMargin
                width: root.pillWidth
                height: root.pillHeight
                radius: height / 2
                color: root.pillColor(root.pillOpacity)

                property real offsetX: 0
                property real offsetY: 0

                transform: Translate { x: pill.offsetX; y: pill.offsetY }

                Behavior on color { ColorAnimation { duration: 110 } }

                // 回位：带缓动的明确动画，两个轴一起滑回原位
                ParallelAnimation {
                    id: returnAnim
                    NumberAnimation {
                        target: pill; property: "offsetX"; to: 0
                        duration: root.returnMs; easing.type: Easing.OutCubic
                    }
                    NumberAnimation {
                        target: pill; property: "offsetY"; to: 0
                        duration: root.returnMs; easing.type: Easing.OutCubic
                    }
                }

            }
        }

        // ==================== 显示 / 收起 ====================
        onShouldShowChanged: {
            if (shouldShow) {
                root.shown = true         // 先建 surface，再从 0 淡入
                root.fadeOpacity = 1.0
            } else {
                root.fadeOpacity = 0.0    // 先 300ms 淡出
                fadeOutTimer.restart()    // 淡完再销毁 surface
            }
        }

        Component.onCompleted: {
            if (shouldShow) {
                root.shown = true
                root.fadeOpacity = 1.0    // 开机直接显示，不做淡入
            }
            console.error("[navpill] window created")
        }

        // ==================== 定时器 ====================
        // 唤出后停留
        Timer {
            id: hideTimer
            interval: root.revealHoldMs
            repeat: false
            onTriggered: root.revealed = false
        }

        // 淡出完成后销毁 surface
        Timer {
            id: fadeOutTimer
            interval: root.fadeMs
            repeat: false
            onTriggered: root.shown = false
        }

        // 感应区示意停留
        Timer {
            id: sensorHideTimer
            interval: 3000
            repeat: false
            onTriggered: sensorZone.opacity = 0
        }

        // 配置热加载（500ms，调设置时能实时看到变化）
        Timer {
            interval: 500
            running: true
            repeat: true
            triggeredOnStart: true
            onTriggered: configProc.running = true
        }

        // 窗口存在性轮询
        Timer {
            interval: 1500
            running: true
            repeat: true
            triggeredOnStart: true
            onTriggered: windowQuery.running = true
        }

        // 底部监听进程的重启退避
        Timer {
            id: watchRestart
            interval: 3000
            repeat: false
            onTriggered: swipeWatch.running = true
        }

        // ==================== 动作表 ====================
        // 键名与设置页 SelectionSetting 的 value 一一对应
        readonly property var actionTable: ({
            "toggle-overview": ["niri", "msg", "action", "toggle-overview"],
            "open-overview": ["niri", "msg", "action", "open-overview"],
            "close-overview": ["niri", "msg", "action", "close-overview"],
            "niri-focus-left": ["niri", "msg", "action", "focus-column-left"],
            "niri-focus-right": ["niri", "msg", "action", "focus-column-right"],
            "niri-focus-up": ["niri", "msg", "action", "focus-window-up"],
            "niri-focus-down": ["niri", "msg", "action", "focus-window-down"],
            "niri-move-left": ["niri", "msg", "action", "move-column-left"],
            "niri-move-right": ["niri", "msg", "action", "move-column-right"],
            "niri-close": ["niri", "msg", "action", "close-window"],
            "niri-fullscreen": ["niri", "msg", "action", "fullscreen-window"],
            "niri-float": ["niri", "msg", "action", "toggle-window-floating"],
            "niri-ws-up": ["niri", "msg", "action", "focus-workspace-up"],
            "niri-ws-down": ["niri", "msg", "action", "focus-workspace-down"],
            "control-center": ["dms", "ipc", "call", "control-center", "toggle"],
            "launcher": ["dms", "ipc", "call", "launcher", "toggle"],
            "notifications": ["dms", "ipc", "call", "notifications", "toggle"],
            "powermenu": ["dms", "ipc", "call", "powermenu", "toggle"],
            "clipboard": ["dms", "ipc", "call", "clipboard", "toggle"],
            "dms-dash": ["dms", "ipc", "call", "dash", "toggle"],
            "dms-vol-up": ["dms", "ipc", "call", "audio", "volumeUp"],
            "dms-vol-down": ["dms", "ipc", "call", "audio", "volumeDown"],
            "dms-mute": ["dms", "ipc", "call", "audio", "toggleMute"],
            "dms-bri-up": ["dms", "ipc", "call", "brightness", "increase"],
            "dms-bri-down": ["dms", "ipc", "call", "brightness", "decrease"]
        })

        function runAction(gesture) {
            const name = root.actionMap[gesture] || "none"
            if (name === "none")
                return
            root.lastActionTime = Date.now()

            if (name === "hide") {
                root.revealed = false
                hideTimer.stop()
                return
            }
            if (name === "custom") {
                const cmd = (root.customMap[gesture] || "").trim()
                if (!cmd)
                    return
                actionProc.command = ["sh", "-c", cmd]
                actionProc.running = true
                return
            }
            const argv = root.actionTable[name]
            if (!argv)
                return
            actionProc.command = argv
            actionProc.running = true
            if (root.revealed)
                hideTimer.restart()
        }

        // ==================== 手势 ====================
        DragHandler {
            target: null
            property real dx: 0
            property real dy: 0

            onActiveChanged: {
                if (active) {
                    hideTimer.stop()
                    dx = 0
                    dy = 0
                    pill.color = root.pillColor(1.0)   // 触摸时全不透明
                } else {
                    pill.color = root.pillColor(root.pillOpacity)

                    // 松手才判定：滑回去 / 位移不够都不触发
                    const horizontal = Math.abs(dx) > Math.abs(dy)
                    const moved = horizontal ? Math.abs(dx) : Math.abs(dy)
                    if (moved >= root.swipeThreshold) {
                        if (horizontal)
                            root.runAction(dx > 0 ? "swipe_right" : "swipe_left")
                        else
                            root.runAction(dy > 0 ? "swipe_down" : "swipe_up")
                    }

                    returnAnim.restart()

                    if (root.revealed)
                        hideTimer.restart()
                }
            }

            onCentroidChanged: {
                if (!active)
                    return

                dx = centroid.position.x - centroid.scenePressPosition.x
                dy = centroid.position.y - centroid.scenePressPosition.y

                // 位移 = 手指位移的 1/5，封顶在条高
                const cap = root.dragLimit
                pill.offsetX = Math.max(-cap, Math.min(cap, dx * root.dragRatio))
                // 向下不给位移
                pill.offsetY = dy < 0
                    ? Math.max(-cap, Math.min(0, dy * root.dragRatio))
                    : 0
            }
        }

        TapHandler {
            acceptedButtons: Qt.LeftButton
            gesturePolicy: TapHandler.ReleaseWithinBounds

            onPressedChanged: {
                if (pressed) {
                    pill.color = root.pillColor(1.0)   // 点击/长按也全不透明
                    hideTimer.stop()
                } else {
                    pill.color = root.pillColor(root.pillOpacity)
                    if (root.revealed)
                        hideTimer.restart()
                }
            }
            onSingleTapped: root.runAction("tap")
            onLongPressed: root.runAction("long_press")
        }

        // ==================== 进程 ====================
        // 配置热加载
        Process {
            id: configProc
            command: ["python3", "-c",
                "import json;" +
                "d=json.load(open('" + Quickshell.env("HOME") + "/.config/dms/plugin_settings.json')).get('nabuNavPill',{});" +
                "d['_g']={g:d.get('action_'+g,'none') for g in ['swipe_up','swipe_down','swipe_left','swipe_right','tap','long_press']};" +
                "d['_c']={g:d.get('custom_action_'+g,'') for g in ['swipe_up','swipe_down','swipe_left','swipe_right','tap','long_press']};" +
                "print(json.dumps(d))"]
            stdout: StdioCollector {
                onStreamFinished: {
                    const raw = text.trim()

                    // 任意设置变了 → 强制唤出 + 显示感应区（首次加载不触发）
                    if (raw && root.lastConfigRaw !== "" && raw !== root.lastConfigRaw) {
                        root.reveal()
                        sensorZone.opacity = 0.55
                        sensorHideTimer.restart()
                    }
                    if (raw)
                        root.lastConfigRaw = raw

                    try {
                        const d = JSON.parse(raw || "{}")
                        root.pillWidth = d.pill_width || 172
                        root.pillHeight = d.pill_height || 6
                        root.pillMargin = d.pill_margin || 6
                        root.pillOpacity = (d.pill_opacity_pct || 75) / 100.0
                        root.revealHoldMs = d.reveal_hold_ms || 3000
                        root.bottomBandPx = d.bottom_band_px || 40
                        if (d._g)
                            root.actionMap = d._g
                        if (d._c)
                            root.customMap = d._c
                    } catch (e) {
                        console.error("[navpill] config parse failed:", e)
                    }
                }
            }
        }

        // 横条隐藏时的底部上滑监听（evdev 只读旁听）
        Process {
            id: swipeWatch
            command: ["python3", Quickshell.env("HOME") +
                      "/.config/dms/plugins/nabuNavPill/scripts/bottom-swipe-watch.py"]
            running: true
            stdout: SplitParser {
                onRead: line => {
                    if (line.trim() !== "BOTTOM_SWIPE")
                        return
                    // 窗口内的滑动 QML 也收到了，400ms 内去重
                    if (Date.now() - root.lastActionTime < 400)
                        return
                    if (root.revealed)
                        root.runAction("swipe_up")
                    else
                        root.reveal()
                }
            }
            onExited: code => {
                if (code !== 0 && code !== 143)
                    watchRestart.restart()
            }
        }

        Process {
            id: actionProc
            command: []
        }

        // niri 窗口存在性（决定是否需要避让）
        Process {
            id: windowQuery
            command: ["niri", "msg", "--json", "windows"]
            stdout: StdioCollector {
                onStreamFinished: {
                    const raw = text.trim()
                    if (!raw) {
                        root.hasWindows = false
                        return
                    }
                    try {
                        const arr = JSON.parse(raw)
                        root.hasWindows = Array.isArray(arr) && arr.length > 0
                    } catch (e) {
                        root.hasWindows = false
                    }
                }
            }
        }
    }
}
