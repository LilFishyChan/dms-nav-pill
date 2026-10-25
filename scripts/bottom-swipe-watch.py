#!/usr/bin/env python3
"""底部上滑监听器。

只做一件事：在触摸屏底部区域识别「单指上滑」，然后往 stdout 打一行
BOTTOM_SWIPE。不拦截触摸（evdev 只读），应用照常收到事件。

给导航横条当"唤出入口"用 —— 横条隐藏时窗口不存在、收不到触摸，
所以要有个旁路的监听者才能知道用户在条的位置上滑了。

阈值全部来自 DMS 的 plugin_settings.json（nabuNavPill 节点），
文件 mtime 一变就重读，改设置不用重启插件。
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

import evdev
from evdev import ecodes

PLUGIN_ID = "nabuNavPill"
SETTINGS = Path(os.path.expanduser("~/.config/dms/plugin_settings.json"))

# 屏幕物理分辨率的缺省值，设备探测失败时用
DEFAULT_W, DEFAULT_H = 1600, 2560

DEFAULTS = {
    "bottom_band_px": 40,       # 底部感应区高度（像素）
    "swipe_min_pct": 5,         # 上滑最小位移（占屏高）
    "vertical_bias_x10": 11,    # |dy| 要比 |dx| 大这么多倍（值 /10）
    "cooldown_ms": 1114,        # 触发后的冷却
}
MAX_FINGERS = 1                 # 只认单指

_NIRI_ENV = None                # NIRI_SOCKET 查一次就够，别每秒 fork systemctl


def load_config() -> dict:
    cfg = dict(DEFAULTS)
    try:
        node = json.loads(SETTINGS.read_text(encoding="utf-8")).get(PLUGIN_ID, {})
        for k in DEFAULTS:
            if k in node:
                cfg[k] = node[k]
    except Exception:  # noqa: BLE001
        pass
    return cfg


def read_output() -> tuple[float, str]:
    """读 niri 的输出缩放和旋转。

    返回 (scale, transform)。evdev 给的是设备原生坐标，不随屏幕旋转变化，
    所以判定"哪条边是屏幕底部"必须靠 transform 换算。
    """
    global _NIRI_ENV
    try:
        if _NIRI_ENV is None:
            env = dict(os.environ)
            if not env.get("NIRI_SOCKET"):
                out = subprocess.run(["systemctl", "--user", "show-environment"],
                                     capture_output=True, text=True, timeout=3).stdout
                for line in out.splitlines():
                    if line.startswith("NIRI_SOCKET="):
                        env["NIRI_SOCKET"] = line.split("=", 1)[1]
                        break
            _NIRI_ENV = env
        env = _NIRI_ENV
        res = subprocess.run(["niri", "msg", "--json", "outputs"],
                             capture_output=True, text=True, timeout=3, env=env)
        data = json.loads(res.stdout)
        for node in data.values():
            logical = node.get("logical") or {}
            scale = logical.get("scale")
            if scale:
                tf = logical.get("transform")
                if isinstance(tf, dict):
                    tf = tf.get("name") or tf.get("type") or "normal"
                return float(scale), str(tf or "normal").lower().replace("_", "-")
    except Exception:  # noqa: BLE001
        pass
    return 1.0, "normal"


def edge_geometry(transform: str, w: int, h: int):
    """屏幕底边在物理坐标里的位置，以及屏幕上滑对应的物理方向。

    evdev 的 (x, y) 是设备原生坐标（竖屏 1600×2560），屏幕转了之后
    用户看到的"底部"和"上滑"都跟着换边，这里换算一次给判定用。

    返回 (轴, 底边坐标, 上滑方向符号)。
    """
    t = transform or "normal"
    if t == "90":
        # 屏幕底部 = 物理右边；屏幕上滑 = x 减小
        return "x", w, -1
    if t == "180":
        # 屏幕底部 = 物理顶部；屏幕上滑 = y 增大
        return "y", 0, +1
    if t == "270":
        # 屏幕底部 = 物理左边；屏幕上滑 = x 增大
        return "x", 0, +1
    # normal：屏幕底部 = 物理底边；屏幕上滑 = y 减小
    return "y", h, -1


def settings_mtime() -> float:
    try:
        return SETTINGS.stat().st_mtime
    except OSError:
        return 0.0


def pick_device():
    for path in sorted(evdev.list_devices()):
        try:
            dev = evdev.InputDevice(path)
        except Exception:  # noqa: BLE001
            continue
        caps = dev.capabilities()
        abs_items = caps.get(ecodes.EV_ABS, [])
        codes = {code for code, _info in abs_items}
        if ecodes.ABS_MT_POSITION_X in codes or ecodes.BTN_TOUCH in set(
            caps.get(ecodes.EV_KEY, [])
        ):
            ranges = {code: info.max for code, info in abs_items}
            return dev, ranges.get(ecodes.ABS_MT_POSITION_X, DEFAULT_W), ranges.get(
                ecodes.ABS_MT_POSITION_Y, DEFAULT_H
            )
    return None, DEFAULT_W, DEFAULT_H


def main() -> int:
    dev, w, h = pick_device()
    if dev is None:
        print("no touchscreen", file=sys.stderr, flush=True)
        return 1

    cfg = load_config()
    scale, transform = read_output()
    mtime = settings_mtime()
    last_check = time.monotonic()

    slots: dict[int, dict] = {}
    cur_slot = 0
    touching = False
    max_fingers = 0
    start = None
    last = None
    last_fire = 0.0

    for event in dev.read_loop():
        # 每秒最多查一次配置改动，改设置无需重启
        now = time.monotonic()
        if now - last_check > 1.0:
            last_check = now
            new = settings_mtime()
            if new != mtime:
                mtime = new
                cfg = load_config()
            # 朝向可能变了，顺手重读一次（很轻，3 秒超时的一次 niri 调用）
            scale, transform = read_output()

        if event.type == ecodes.EV_ABS:
            code, val = event.code, event.value
            if code == ecodes.ABS_MT_SLOT:
                cur_slot = val
            elif code == ecodes.ABS_MT_TRACKING_ID:
                if val == -1:
                    slots.pop(cur_slot, None)
                else:
                    slots[cur_slot] = {"x": None, "y": None}
            elif code == ecodes.ABS_MT_POSITION_X:
                slots.setdefault(cur_slot, {"x": None, "y": None})["x"] = val
            elif code == ecodes.ABS_MT_POSITION_Y:
                slots.setdefault(cur_slot, {"x": None, "y": None})["y"] = val

        elif event.type == ecodes.EV_KEY and event.code == ecodes.BTN_TOUCH:
            if event.value == 1:
                touching = True
                max_fingers, start, last = 0, None, None
            else:
                if touching and start and last and max_fingers <= MAX_FINGERS:
                    band_px = cfg["bottom_band_px"] * scale
                    min_swipe = cfg["swipe_min_pct"] / 100.0
                    bias = cfg["vertical_bias_x10"] / 10.0
                    cooldown = cfg["cooldown_ms"] / 1000.0

                    axis, edge_pos, sign = edge_geometry(transform, w, h)
                    if axis == "y":
                        along = (last[1] - start[1]) * sign    # >0 = 朝屏幕上方
                        across = (last[0] - start[0])
                        span, span_across = h, w
                        started_low = abs(start[1] - edge_pos) <= band_px
                    else:
                        along = (last[0] - start[0]) * sign
                        across = (last[1] - start[1])
                        span, span_across = w, h
                        started_low = abs(start[0] - edge_pos) <= band_px

                    moved = along / span
                    sideways = abs(across) / span_across
                    vertical = moved > sideways * bias
                    t = time.monotonic()
                    if (started_low and vertical and moved > min_swipe
                            and t - last_fire > cooldown):
                        last_fire = t
                        print("BOTTOM_SWIPE", flush=True)
                touching = False
                slots.clear()

        elif event.type == ecodes.EV_SYN and event.code == ecodes.SYN_REPORT:
            if not touching:
                continue
            live = [s for s in slots.values()
                    if s.get("x") is not None and s.get("y") is not None]
            if not live:
                continue
            max_fingers = max(max_fingers, len(live))
            if start is None:
                start = (live[0]["x"], live[0]["y"])
            last = (live[0]["x"], live[0]["y"])

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
    except PermissionError:
        print("permission denied: user must be in the input group", file=sys.stderr, flush=True)
        sys.exit(2)
