#!/bin/bash
# PocketTerm35 触摸手势 — 一键安装 / 卸载
#
#   安装：sudo bash install.sh
#   卸载：sudo bash install.sh --uninstall
#
# 适用：Kali / Debian 系的 X11 桌面
# 依赖：python3、libX11、libXtst、xdotool、wmctrl、xrandr
#
# 原理：PT35 的 Goodix GT911 被内核报告为 cap=kt（触摸屏，不是触摸板），
#       libinput 因此不提供 tap/scroll/gesture，X 的 evdev 驱动也只把第一根
#       手指当鼠标。本程序用 EVIOCGRAB 独占触屏，解析 type-B multi-touch，
#       再用 XTest 合成鼠标/键盘事件。
#
# 脚本内嵌守护程序源码，安装后写入 /usr/local/bin/ptk-touch-gesture。

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "请用 sudo 运行： sudo bash $0" >&2
    exit 1
fi

BIN=/usr/local/bin/ptk-touch-gesture
DESKTOP=/etc/xdg/autostart/pocketterm35-touch-gesture.desktop

stop_daemon() {
    for p in $(pgrep -f "ptk-touch-gesture" 2>/dev/null); do
        cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || true)
        case "$cmd" in
            python3*) kill "$p" 2>/dev/null || true ;;
        esac
    done
}

# ---------------- 卸载 ----------------
if [ "${1:-}" = "--uninstall" ]; then
    stop_daemon
    rm -f "$BIN" "$DESKTOP"
    echo "已卸载。触摸屏恢复系统默认行为（单指点击）。"
    exit 0
fi

# ---------------- 依赖 ----------------
need=()
command -v xdotool >/dev/null 2>&1 || need+=(xdotool)
command -v wmctrl  >/dev/null 2>&1 || need+=(wmctrl)
command -v xrandr  >/dev/null 2>&1 || need+=(x11-xserver-utils)
if [ ${#need[@]} -gt 0 ]; then
    echo "安装依赖：${need[*]}"
    apt-get update -qq 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${need[@]}"
fi

# ---------------- 安装守护 ----------------
echo "写入 $BIN"
mkdir -p /usr/local/bin
cat > "$BIN.new" <<'PTK_EOF'
#!/usr/bin/env python3
"""PocketTerm35 触摸手势守护进程

背景
  PT35 的 Goodix GT911 被内核报告为 cap=kt（触摸屏，不是触摸板，带
  INPUT_PROP_DIRECT）。libinput 因此不提供 tap/scroll/gesture；X 的 evdev
  驱动也只把第一根手指当鼠标左键，多指直接丢弃。

  本程序用 EVIOCGRAB 独占触屏设备，解析 type-B multi-touch，再用 XTest
  合成鼠标/键盘事件。

手势
  单指  轻点 / 双击 / 长按0.6s / 拖动   左键 / 打开 / 右键 / 拖动
  双指  轻点 / 上下滑 / 左右滑          中键 / 滚动 / 后退前进
  三指  轻点 / 上滑 / 下滑 / 左右滑     右键 / 最大化 / 最小化 / 切换工作区
  四指  轻点 / 上滑 / 下滑              切换指针模式 / 放大1.5x / 恢复

指针模式（四指点按切换）
  单指滑动           相对移动指针
  轻点               左键
  按住0.22s后移动    拖动（在指针当前位置按下左键）
  按住不动0.6s       右键

用法
  ptk-touch-gesture            正常运行（需 root 或 input 组）
  ptk-touch-gesture -d         打印识别过程
  ptk-touch-gesture --no-grab  不独占设备（单指仍由 X 处理）
"""
import ctypes
import fcntl
import glob
import os
import select
import struct
import subprocess
import sys
import time

DISPLAY = os.environ.get("DISPLAY", ":0.0")

# Linux input 事件码
EV_ABS = 3
ABS_MT_SLOT = 0x2F
ABS_MT_POSITION_X = 0x35
ABS_MT_POSITION_Y = 0x36
ABS_MT_TRACKING_ID = 0x39
ABS_X = 0x00
ABS_Y = 0x01
EVIOCGRAB = 0x40044590


def _eviocgabs(axis):
    """_IOR('E', 0x40 + axis, struct input_absinfo) —— 24 字节"""
    return (2 << 30) | (24 << 16) | ((0x40 + axis) << 8) | ord("E")


# 手势参数
CLICK_DELAY = 0.060     # 单指落下后多久确认是单指（避免两指时先闪一个左键）
TAP_MS = 0.400          # 单指点按最长时长
MULTI_TAP_MS = 1.000    # 三/四指点按最长时长（多指操作本来就慢）
TAP_MOVE = 15           # 点按允许的最大位移(px)
SWIPE_EDGE = 60         # 滑动最小位移(px)
SWIPE_MS = 0.700        # 滑动最长时长
AXIS_RATIO = 0.6        # 主方向 / 次方向 的比例下限（多指滑动难以完全对齐）
HOLD_MS = 0.600         # 长按 -> 右键
HOLD_MOVE = 12          # 绝对模式长按的静止容差(px)
POINTER_STILL = 35      # 指针模式长按的静止容差(px)，触摸屏按住时会抖
DRAG_HOLD = 0.220       # 指针模式按住多久进入拖动预备
DRAG_MOVE = 5           # 拖动预备后移动多少像素才真正按下左键
DOUBLE_MS = 0.400       # 双击最大间隔
DOUBLE_DIST = 30        # 双击允许的位置偏差(px)
SCROLL_STEP = 18        # 每 18px 发一格滚轮
SCROLL_JUMP = 40        # 单帧位移超过此值视为跳变，忽略
MAX_JUMP = 100          # 指针模式下单帧位移超过此值视为跳变，忽略
POINTER_GAIN = 1.5      # 指针模式位移放大倍数
ZOOM_FACTOR = 1.5       # 四指上滑的缩放倍数

DEBUG = "-d" in sys.argv or "--debug" in sys.argv


def log(msg):
    if DEBUG:
        print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def find_touch_device():
    """按名字查找触屏设备（event 编号在不同机器上可能不同）。

    PTK_TOUCH_DEVICE=/dev/input/eventN 可强制指定。
    """
    forced = os.environ.get("PTK_TOUCH_DEVICE")
    if forced:
        return forced
    for path in sorted(glob.glob("/dev/input/event*")):
        name_file = f"/sys/class/input/{os.path.basename(path)}/device/name"
        try:
            with open(name_file, "r", errors="ignore") as f:
                name = f.read().strip().lower()
        except OSError:
            continue
        if "goodix" in name or "touchscreen" in name:
            return path
    return None


def read_abs_range(fd, axis):
    """读取某个 ABS 轴的 (min, max)；失败时返回 None。"""
    try:
        buf = fcntl.ioctl(fd, _eviocgabs(axis), b"\0" * 24)
        _value, minimum, maximum = struct.unpack_from("<3i", buf)
        return minimum, maximum
    except OSError:
        return None


class XInput:
    """用 libX11 + libXtst 合成输入事件（不需要 fork xdotool）。"""

    def __init__(self):
        self.x11 = ctypes.CDLL("libX11.so.6")
        self.xtst = ctypes.CDLL("libXtst.so.6")

        self.x11.XOpenDisplay.restype = ctypes.c_void_p
        self.x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
        self.x11.XFlush.argtypes = [ctypes.c_void_p]
        self.x11.XStringToKeysym.restype = ctypes.c_ulong
        self.x11.XStringToKeysym.argtypes = [ctypes.c_char_p]
        self.x11.XKeysymToKeycode.restype = ctypes.c_ubyte
        self.x11.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        self.x11.XDefaultRootWindow.restype = ctypes.c_ulong
        self.x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        self.x11.XGetGeometry.argtypes = [
            ctypes.c_void_p, ctypes.c_ulong,
            ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int),
            ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_uint),
            ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint),
            ctypes.POINTER(ctypes.c_uint)]
        self.xtst.XTestFakeMotionEvent.argtypes = [
            ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ulong]
        self.xtst.XTestFakeRelativeMotionEvent.argtypes = [
            ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_ulong]
        self.xtst.XTestFakeButtonEvent.argtypes = [
            ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
        self.xtst.XTestFakeKeyEvent.argtypes = [
            ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]

        self.dpy = self.x11.XOpenDisplay(DISPLAY.encode())
        if not self.dpy:
            raise RuntimeError(f"无法打开 X display {DISPLAY!r}")

        # 触屏原始坐标范围，main() 里按实际设备更新
        self.raw_x = (0, 639)
        self.raw_y = (0, 479)

    def set_raw_range(self, x_range, y_range):
        if x_range and x_range[1] > x_range[0]:
            self.raw_x = x_range
        if y_range and y_range[1] > y_range[0]:
            self.raw_y = y_range

    def _flush(self):
        self.x11.XFlush(ctypes.c_void_p(self.dpy))

    def screen_size(self):
        """实时查询根窗口尺寸。

        不能用 XDisplayWidth/Height —— 那是 XOpenDisplay 时的缓存值，
        xrandr 改分辨率后不会更新，会导致触摸漂移。
        """
        dpy = ctypes.c_void_p(self.dpy)
        root = self.x11.XDefaultRootWindow(dpy)
        rr = ctypes.c_ulong()
        x = ctypes.c_int()
        y = ctypes.c_int()
        w = ctypes.c_uint()
        h = ctypes.c_uint()
        bw = ctypes.c_uint()
        dep = ctypes.c_uint()
        self.x11.XGetGeometry(dpy, root, ctypes.byref(rr),
                              ctypes.byref(x), ctypes.byref(y),
                              ctypes.byref(w), ctypes.byref(h),
                              ctypes.byref(bw), ctypes.byref(dep))
        return (w.value or 640, h.value or 480)

    def _map(self, x, y):
        """触屏原始坐标 -> 屏幕像素。"""
        sw, sh = self.screen_size()
        xmin, xmax = self.raw_x
        ymin, ymax = self.raw_y
        sx = (x - xmin) / (xmax - xmin) * (sw - 1)
        sy = (y - ymin) / (ymax - ymin) * (sh - 1)
        return int(sx), int(sy)

    def move(self, x, y):
        sx, sy = self._map(x, y)
        self.xtst.XTestFakeMotionEvent(
            ctypes.c_void_p(self.dpy), -1, sx, sy, 0)
        self._flush()

    def move_rel(self, dx, dy):
        self.xtst.XTestFakeRelativeMotionEvent(
            ctypes.c_void_p(self.dpy), int(round(dx)), int(round(dy)), 0)
        self._flush()

    def button(self, b, press):
        self.xtst.XTestFakeButtonEvent(
            ctypes.c_void_p(self.dpy), int(b), 1 if press else 0, 0)
        self._flush()

    def click(self, b):
        self.button(b, True)
        self.button(b, False)

    def combo(self, modifier, keysym):
        mkc = self.x11.XKeysymToKeycode(
            ctypes.c_void_p(self.dpy),
            self.x11.XStringToKeysym(modifier.encode()))
        kc = self.x11.XKeysymToKeycode(
            ctypes.c_void_p(self.dpy),
            self.x11.XStringToKeysym(keysym.encode()))
        if not (mkc and kc):
            return
        dpy = ctypes.c_void_p(self.dpy)
        self.xtst.XTestFakeKeyEvent(dpy, mkc, 1, 0)
        self.xtst.XTestFakeKeyEvent(dpy, kc, 1, 0)
        self.xtst.XTestFakeKeyEvent(dpy, kc, 0, 0)
        self.xtst.XTestFakeKeyEvent(dpy, mkc, 0, 0)
        self._flush()


def _run(cmd, timeout=3):
    """执行外部命令；失败时记录 stderr（便于诊断）。"""
    env = {**os.environ, "DISPLAY": DISPLAY}
    try:
        r = subprocess.run(cmd, env=env, timeout=timeout,
                           capture_output=True, text=True)
        if r.returncode != 0:
            log(f"! {' '.join(cmd)} -> rc={r.returncode} {r.stderr.strip()[:120]}")
        return r
    except Exception as e:
        log(f"! {' '.join(cmd)} -> {e}")
        return None


def output_name():
    """当前连接的主输出名（PT35 上是 HDMI-1）。"""
    r = _run(["xrandr", "--listmonitors"])
    if r and r.stdout:
        lines = [l for l in r.stdout.splitlines() if l.strip()]
        if len(lines) > 1:
            return lines[1].split()[-1]
    return "HDMI-1"


def set_zoom(on):
    """四指上/下滑：切换 / 恢复 1.5 倍缩放。"""
    out = output_name()
    if on:
        _run(["xrandr", "--output", out, "--transform",
              f"{ZOOM_FACTOR},0,0,0,{ZOOM_FACTOR},0,0,0,1"])
    else:
        _run(["xrandr", "--output", out, "--transform", "none"])
        _run(["xrandr", "--output", out, "--mode", "640x480"])
        _run(["xrandr", "--fb", "640x480"])
    log(f"缩放 {'%.1fx' % ZOOM_FACTOR if on else '恢复'}")


def window_action(action):
    """最大化 / 最小化当前窗口。

    xdotool 没有 windowmaximize（只有 windowminimize），
    最大化必须用 wmctrl 设置 _NET_WM_STATE。
    """
    r = _run(["xdotool", "getactivewindow"])
    if not r or not r.stdout.strip():
        log(f"{action}: 取不到活动窗口")
        return
    try:
        wid = int(r.stdout.strip())
    except ValueError:
        return
    hexid = f"0x{wid:08x}"

    name_r = _run(["xdotool", "getwindowname", str(wid)])
    name = name_r.stdout.strip() if name_r else "?"
    if name in ("桌面", "Desktop"):
        log(f"{action}: 当前是桌面，跳过")
        return

    if action == "maximize":
        _run(["wmctrl", "-i", "-r", hexid, "-b",
              "add,maximized_vert,maximized_horz"])
    else:
        _run(["xdotool", "windowminimize", str(wid)])
    log(f"{action} -> {hexid} ({name})")


def switch_workspace(direction):
    """切换工作区（xfce/mate 默认 Ctrl+Alt+Left/Right）。"""
    _run(["xdotool", "key",
          "ctrl+alt+Left" if direction < 0 else "ctrl+alt+Right"])


class Gesture:
    """type-B multi-touch 状态机。"""

    def __init__(self, x):
        self.x = x
        self.slots = {}
        self.slot_start = {}
        self.cur_slot = 0
        self.reset_counters()
        self.pointer_mode = False    # 四指点按切换
        self.last_tap_t = None
        self.last_tap_xy = None

    def reset_counters(self):
        """重置一次触摸过程的计数与标志（不清空 slots）。"""
        self.state = "idle"          # idle | pending | pointer | gesture
        self.t_start = 0.0
        self.pointer_start = 0.0
        self.max_fingers = 0
        self.start_xy = None         # 手势起始中心
        self.stable_xy = None        # 手指数稳定时的最后中心
        self.max_move = 0.0          # 手指相对各自起点的最大位移
        self.scroll_acc = 0.0
        self.last_scroll_y = None
        self.did_scroll = False
        self.dragging = False
        self.long_pressed = False
        self.prev_xy = None
        self.drag_started = False
        self.drag_ready = False

    def reset_touch(self):
        """完全重置（含 slots），用于一次手势结束。"""
        self.slots.clear()
        self.slot_start.clear()
        self.reset_counters()

    # ---- 事件解析 --------------------------------------------------
    def feed(self, etype, code, value):
        if etype != EV_ABS:
            return
        if code == ABS_MT_SLOT:
            self.cur_slot = value
        elif code == ABS_MT_TRACKING_ID:
            if value == -1:
                if self.cur_slot in self.slots:
                    self.slots.pop(self.cur_slot, None)
                    self.slot_start.pop(self.cur_slot, None)
                    log(f"slot {self.cur_slot} 抬起（剩 {len(self.slots)} 指）")
            else:
                self.slots.setdefault(self.cur_slot, {"x": 0, "y": 0})
                log(f"slot {self.cur_slot} 按下（共 {len(self.slots)} 指）")
        elif code == ABS_MT_POSITION_X:
            self.slots.setdefault(self.cur_slot, {"x": 0, "y": 0})["x"] = value
        elif code == ABS_MT_POSITION_Y:
            self.slots.setdefault(self.cur_slot, {"x": 0, "y": 0})["y"] = value

    def center(self):
        if not self.slots:
            return None
        xs = [s["x"] for s in self.slots.values()]
        ys = [s["y"] for s in self.slots.values()]
        return (sum(xs) / len(xs), sum(ys) / len(ys))

    def track_movement(self):
        """更新 max_move。

        起点必须在 tick 里记录（此时 POSITION 事件已到达），不能在
        TRACKING_ID 事件里记录 —— 那一刻坐标还是 0。
        """
        for slot, pos in self.slots.items():
            if slot not in self.slot_start:
                self.slot_start[slot] = (pos["x"], pos["y"])
                continue
            sx, sy = self.slot_start[slot]
            d = max(abs(pos["x"] - sx), abs(pos["y"] - sy))
            if d > self.max_move:
                self.max_move = d

    def do_tap(self, now):
        """单指轻点：自动区分单击 / 双击。"""
        if not self.stable_xy:
            return
        xy = self.stable_xy
        is_double = (
            self.last_tap_t is not None
            and now - self.last_tap_t < DOUBLE_MS
            and self.last_tap_xy is not None
            and abs(xy[0] - self.last_tap_xy[0]) < DOUBLE_DIST
            and abs(xy[1] - self.last_tap_xy[1]) < DOUBLE_DIST
        )
        if is_double:
            # 第二击不移动指针，保持与第一击同坐标，否则系统不认双击
            self.x.click(1)
            log(f"双击 -> 打开 ({xy[0]:.0f},{xy[1]:.0f})")
            self.last_tap_t = None
            self.last_tap_xy = None
        else:
            self.x.move(*xy)
            self.x.click(1)
            log(f"单击 -> 左键 ({xy[0]:.0f},{xy[1]:.0f})")
            self.last_tap_t = now
            self.last_tap_xy = xy

    # ---- 状态推进（每 10ms 调用一次）--------------------------------
    def tick(self, now):
        n = len(self.slots)
        c = self.center()
        self.track_movement()

        if self.state == "idle":
            if n >= 1:
                self.reset_counters()
                self.state = "pending"
                self.t_start = now
                self.max_fingers = n
                self.start_xy = c
                self.stable_xy = c
            return

        if self.state == "pending":
            self.max_fingers = max(self.max_fingers, n)
            if c:
                self.stable_xy = c
            if n >= 2:
                self.state = "gesture"
                self.start_xy = c
                self.stable_xy = c
                log(f"进入手势模式（{n} 指）")
            elif n == 0:
                # 手指已抬起：只要没移动就当作一次点击
                #（正常情况下 0.06s 后先进入 pointer；这里是兜底，
                #  避免某一帧同时"超时 + 抬起"时丢掉点击）
                if now - self.t_start < TAP_MS and self.max_move < TAP_MOVE:
                    self.do_tap(now)
                self.state = "idle"
            elif now - self.t_start >= CLICK_DELAY:
                self.state = "pointer"
                self.pointer_start = now
                if self.pointer_mode:
                    # 指针模式：不按下、不跳位置，只记录起点
                    self.prev_xy = c
                    log("指针模式：开始移动指针")
                    return
                self.dragging = True
                self._press_at(now, c)
            return

        if self.state == "pointer":
            if n >= 2:
                if self.dragging:
                    self.x.button(1, False)
                    self.dragging = False
                self.state = "gesture"
                self.max_fingers = max(self.max_fingers, n)
                self.start_xy = c
                self.stable_xy = c
                self.prev_xy = None
                log("单指 -> 手势")
                return

            if n == 0:
                self._release(now)
                self.state = "idle"
                return

            if self.pointer_mode:
                self._pointer_move(now, c)
            else:
                self._absolute_move(now, c)
            return

        if self.state == "gesture":
            self.max_fingers = max(self.max_fingers, n)
            if n == 0:
                self.finish(now)
                return
            # 手指数稳定时才更新中心，避免抬手瞬间漂移
            if n == self.max_fingers and c:
                self.stable_xy = c
                if self.start_xy is None:
                    self.start_xy = c
                if n == 2:
                    self._scroll(c)
            return

    # ---- 各状态细节 -------------------------------------------------
    def _press_at(self, now, c):
        """绝对模式下按下左键；若靠近上次点击则对齐坐标以利双击。"""
        aligned = False
        if (self.last_tap_t is not None
                and self.last_tap_xy is not None
                and now - self.last_tap_t < DOUBLE_MS
                and abs(c[0] - self.last_tap_xy[0]) < DOUBLE_DIST
                and abs(c[1] - self.last_tap_xy[1]) < DOUBLE_DIST):
            self.x.move(*self.last_tap_xy)
            aligned = True
            log("双击第二击 -> 对齐到第一击位置")
        if not aligned and c:
            self.x.move(*c)
        self.x.button(1, True)
        log("单指 -> 左键按下")

    def _release(self, now):
        """单指抬起：结束拖动 / 记录点击。"""
        if self.pointer_mode:
            dur = now - self.pointer_start
            if self.drag_started:
                self.x.button(1, False)
                self.drag_started = False
                log(f"指针模式：拖动结束（{dur:.2f}s）")
            elif dur < TAP_MS and self.max_move < TAP_MOVE:
                self.x.click(1)
                log(f"指针模式：单击（{dur:.2f}s）")
            elif self.long_pressed:
                log("指针模式：右键结束")
            self.prev_xy = None
            return

        if self.dragging:
            self.x.button(1, False)
            self.dragging = False
            if now - self.pointer_start < TAP_MS and self.max_move < TAP_MOVE:
                pos = self.stable_xy or self.start_xy
                self.last_tap_t = now
                self.last_tap_xy = pos
                log(f"单指点击 -> 左键 ({pos[0]:.0f},{pos[1]:.0f})")
            else:
                log("单指拖动结束")
        elif self.long_pressed:
            log("右键结束")

    def _absolute_move(self, now, c):
        """绝对模式：长按不动 -> 右键；否则指针跟手。"""
        if (self.dragging
                and now - self.pointer_start >= HOLD_MS
                and self.max_move < HOLD_MOVE):
            self.x.button(1, False)
            self.dragging = False
            self.long_pressed = True
            self.x.click(3)
            log(f"单指长按 -> 右键（{now - self.pointer_start:.2f}s）")
        if c:
            self.stable_xy = c
            self.x.move(*c)

    def _pointer_move(self, now, c):
        """指针模式：相对移动 + 拖动预备/开始 + 长按右键。"""
        dur = now - self.pointer_start

        if self.prev_xy and c:
            dx = c[0] - self.prev_xy[0]
            dy = c[1] - self.prev_xy[1]
            if abs(dx) < MAX_JUMP and abs(dy) < MAX_JUMP:
                self.x.move_rel(dx * POINTER_GAIN, dy * POINTER_GAIN)
        self.prev_xy = c

        # 按住不动 0.22s -> 拖动预备（先不按左键，避免长按右键时误拖）
        if (not self.drag_ready
                and not self.long_pressed
                and dur >= DRAG_HOLD
                and self.max_move < POINTER_STILL):
            self.drag_ready = True
            log("指针模式：拖动预备")

        # 预备后真的移动了 -> 这时才按下左键
        if (self.drag_ready
                and not self.drag_started
                and not self.long_pressed
                and self.max_move > DRAG_MOVE):
            self.x.button(1, True)
            self.drag_started = True
            log("指针模式：开始拖动（左键已按下）")

        # 一直不动到 0.6s -> 右键（已经开始拖动则不再触发）
        if (not self.long_pressed
                and not self.drag_started
                and dur >= HOLD_MS
                and self.max_move < POINTER_STILL):
            self.long_pressed = True
            self.x.click(3)
            log(f"指针模式：长按 -> 右键（{dur:.2f}s）")

    def _scroll(self, c):
        """两指纵向滑动 -> 滚轮。"""
        if self.last_scroll_y is None:
            self.last_scroll_y = c[1]
            return
        dy = c[1] - self.last_scroll_y
        if abs(dy) < SCROLL_JUMP:
            self.scroll_acc += dy
            while abs(self.scroll_acc) >= SCROLL_STEP:
                # 手指上滑(dy<0) = 内容下移 = 向下滚动(button 5)
                self.x.click(5 if self.scroll_acc < 0 else 4)
                self.scroll_acc += SCROLL_STEP if self.scroll_acc < 0 else -SCROLL_STEP
                self.did_scroll = True
        self.last_scroll_y = c[1]

    def finish(self, now):
        """所有手指抬起：判定三/四指手势。"""
        dur = now - self.t_start
        n = self.max_fingers
        dx = dy = 0.0
        if self.start_xy and self.stable_xy:
            dx = self.stable_xy[0] - self.start_xy[0]
            dy = self.stable_xy[1] - self.start_xy[1]
        move = self.max_move

        if self.dragging:
            self.x.button(1, False)
            self.dragging = False

        vertical = abs(dy) > SWIPE_EDGE and abs(dy) >= abs(dx) * AXIS_RATIO
        horizontal = abs(dx) > SWIPE_EDGE and abs(dx) >= abs(dy) * AXIS_RATIO
        in_time = dur < SWIPE_MS

        if n == 2:
            if dur < TAP_MS and move < TAP_MOVE:
                self.x.click(2)
                log(f"两指点按 -> 中键（{dur:.2f}s）")
            elif horizontal and in_time:
                self.x.combo("Alt_L", "Left" if dx < 0 else "Right")
                log(f"两指{'左' if dx < 0 else '右'}滑 -> 浏览器{'后退' if dx < 0 else '前进'}")
            elif self.did_scroll:
                log("两指滚动完成")
            else:
                log(f"两指手势未匹配（{dur:.2f}s move={move:.0f}）")
        elif n == 3:
            if dur < MULTI_TAP_MS and move < TAP_MOVE:
                self.x.click(3)
                log("三指点按 -> 右键")
            elif vertical and in_time:
                window_action("maximize" if dy < 0 else "minimize")
                log(f"三指{'上' if dy < 0 else '下'}滑 -> {'最大化' if dy < 0 else '最小化'}")
            elif horizontal and in_time:
                switch_workspace(-1 if dx < 0 else 1)
                log(f"三指{'左' if dx < 0 else '右'}滑 -> 切换工作区")
            else:
                log(f"三指手势未匹配（{dur:.2f}s move={move:.0f}）")
        elif n >= 4:
            if dur < MULTI_TAP_MS and move < TAP_MOVE:
                self.pointer_mode = not self.pointer_mode
                log(f"四指点按 -> {'进入' if self.pointer_mode else '退出'}指针模式")
            elif vertical and in_time:
                set_zoom(dy < 0)
                log(f"四指{'上' if dy < 0 else '下'}滑 -> {'放大' if dy < 0 else '恢复缩放'}")
            else:
                log(f"四指手势未匹配（{dur:.2f}s move={move:.0f}）")

        self.state = "idle"
        self.reset_touch()


def main():
    dev_path = find_touch_device()
    if not dev_path or not os.path.exists(dev_path):
        print("找不到触摸屏设备（可用 PTK_TOUCH_DEVICE=/dev/input/eventN 指定）",
              file=sys.stderr)
        return 2
    log(f"使用触摸设备 {dev_path}")

    fd = os.open(dev_path, os.O_RDONLY | os.O_NONBLOCK)

    grabbed = False
    if "--no-grab" not in sys.argv:
        try:
            fcntl.ioctl(fd, EVIOCGRAB, 1)
            grabbed = True
        except OSError as e:
            print(f"警告：无法独占触屏（{e}）；单指由 X 处理，多指手势仍可用",
                  file=sys.stderr)

    x = XInput()
    x.set_raw_range(read_abs_range(fd, ABS_X), read_abs_range(fd, ABS_Y))
    g = Gesture(x)
    log(f"已启动（grab={grabbed}，raw x={x.raw_x} y={x.raw_y}）")

    try:
        while True:
            r, _, _ = select.select([fd], [], [], 0.01)
            if r:
                data = os.read(fd, 24 * 128)
                for off in range(0, len(data) - 23, 24):
                    _sec, _usec, etype, code, value = struct.unpack_from(
                        "<qqHHi", data, off)
                    g.feed(etype, code, value)
            g.tick(time.monotonic())
    except KeyboardInterrupt:
        pass
    finally:
        if grabbed:
            try:
                fcntl.ioctl(fd, EVIOCGRAB, 0)
            except OSError:
                pass
        os.close(fd)
        log("退出")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PTK_EOF
chmod 0755 "$BIN.new"
mv "$BIN.new" "$BIN"

# ---------------- 开机自启 ----------------
mkdir -p /etc/xdg/autostart
cat > "$DESKTOP" <<'EOF'
[Desktop Entry]
Type=Application
Name=PocketTerm35 touch gestures
Comment=Single/two/three/four-finger gestures for the Goodix touchscreen
Exec=/usr/local/bin/ptk-touch-gesture
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=2
EOF

# ---------------- 立即启动 ----------------
stop_daemon
sleep 0.5
RUN_USER="${SUDO_USER:-}"
if [ -z "$RUN_USER" ]; then
    RUN_USER=$(getent passwd | awk -F: '$3>=1000 && $3<65534 {print $1; exit}')
fi
if [ -n "${RUN_USER:-}" ] && [ -S /tmp/.X11-unix/X0 ]; then
    sudo -u "$RUN_USER" env DISPLAY=:0.0 \
        XAUTHORITY="/home/$RUN_USER/.Xauthority" \
        setsid nohup "$BIN" >/dev/null 2>&1 &
    sleep 1
fi

if pgrep -f "python3 $BIN" >/dev/null 2>&1; then
    echo "已启动（PID $(pgrep -f "python3 $BIN" | head -1)）"
else
    echo "提示：守护未立即启动，登录桌面后会自动拉起"
fi

echo
echo "安装完成。手势："
echo "  单指  轻点 / 双击 / 长按0.6s / 拖动   → 左键 / 打开 / 右键 / 拖动"
echo "  双指  轻点 / 上下滑 / 左右滑          → 中键 / 滚动 / 后退前进"
echo "  三指  轻点 / 上滑 / 下滑 / 左右滑     → 右键 / 最大化 / 最小化 / 切换工作区"
echo "  四指  轻点 / 上滑 / 下滑              → 切换指针模式 / 放大1.5x / 恢复"
echo
echo "调试：ptk-touch-gesture -d"
echo "卸载：sudo bash $0 --uninstall"
