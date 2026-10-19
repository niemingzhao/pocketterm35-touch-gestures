# PocketTerm35 触摸手势

给 **Waveshare PocketTerm35**（Raspberry Pi 4B / 5 手持终端，Goodix GT911
5 点电容触控）在 **Kali / Debian + X11** 下补齐多点触摸手势。

单文件、零配置、可移植。

---

## 一键安装

```bash
sudo bash install.sh
```

卸载：

```bash
sudo bash install.sh --uninstall
```

安装脚本会：

- 写入 `/usr/local/bin/ptk-touch-gesture`
- 写入 `/etc/xdg/autostart/pocketterm35-touch-gesture.desktop`（登录自动启动）
- 缺少时自动安装 `xdotool`、`wmctrl`、`x11-xserver-utils`
- 将桌面用户加入 `input` 组（读取触屏设备所需，下次登录生效）
- 立即以该用户身份启动守护进程

**不改动** `/boot`、X 配置、桌面环境、分辨率、DPI、登录设置。
卸载后触摸屏恢复系统默认行为（单指点击）。

---

## 手势一览

### 单指

| 手势 | 动作 |
|---|---|
| 轻点 | 左键 |
| 快速点两下 | 双击（打开文件 / 程序） |
| 按住不动 0.6 秒 | 右键菜单 |
| 按住并移动 | 拖动（拖窗口 / 选文字 / 拖滚动条） |

### 双指

| 手势 | 动作 |
|---|---|
| 轻点 | 中键（粘贴 / 关闭标签页） |
| 上下滑 | 滚动 |
| 左右滑 | 浏览器后退 / 前进（Alt+← / Alt+→） |

### 三指

| 手势 | 动作 |
|---|---|
| 轻点 | 右键菜单 |
| 上滑 | 最大化当前窗口 |
| 下滑 | 最小化当前窗口 |
| 左滑 / 右滑 | 切换工作区 |

### 四指

| 手势 | 动作 |
|---|---|
| 轻点 | 切换「指针模式」 |
| 上滑 | 放大 1.5 倍（`xrandr --transform 1.5`） |
| 下滑 | 恢复正常缩放（640×480） |

---

## 指针模式

四指点按进入 / 退出。进入后触摸屏变成触摸板：

| 动作 | 效果 |
|---|---|
| 单指滑动 | 指针**相对移动**（1px 手指 → 1.5px 指针），不再跳到手指位置 |
| 单指轻点 | 左键（在指针当前位置） |
| 快速点两下 | 双击 |
| 双击后按住并移动 | **拖动**：在指针当前位置按下左键并跟随移动 |
| 按住不动 0.6 秒 | 右键 |
| 双指 / 三指手势 | 与普通模式相同 |

适合点很小的按钮、拖滚动条、在终端里选文字。

> 指针模式下，普通单指按住滑动**只移动指针**，不会按下左键，也不会触发点击。
> 拖动必须先用「双击」明确进入：第一击是普通左键，第二击落下后先不按左键；
> 只有第二击期间移动超过 5px 才按下左键开始拖动。第二击没移动就抬起，则补成
> 双击的第二下点击。这样既保留单击 / 双击 / 长按右键，又避免滑动时误触点击或拖动。

---

## 为什么需要它

PT35 的 Goodix GT911 被内核报告为 `cap=kt`（触摸屏，带 `INPUT_PROP_DIRECT`）：

- **libinput** 把它当触摸屏，`Tap-to-click` / `Scroll methods` / 手势全是 `n/a`；
- **X server 的 evdev 驱动**只把第一根手指模拟成鼠标左键，多指直接丢弃；
- **evdev 的 `Third Button Emulation` / `Wheel Emulation`** 只对真实鼠标按键
  做合并，对触摸事件（`BTN_TOUCH`）无效。

所以本项目用 `EVIOCGRAB` 独占触屏设备，自己解析 type-B multi-touch，
再用 `XTest` 合成鼠标/键盘事件。

守护进程退出（崩溃 / 被 kill）时内核会自动释放 grab，触摸立刻回到 X 默认
行为，不会把屏幕锁死。

---

## 移植到其它 PT35

- **设备自动识别**：按名字查找包含 `Goodix` 或 `touchscreen` 的
  `/dev/input/event*`，不同机器 event 编号不同也能用。
- 也可以用环境变量强制指定：
  ```bash
  sudo PTK_TOUCH_DEVICE=/dev/input/event5 bash install.sh
  ```
- **坐标实时映射**：每次移动都用 `XGetGeometry(root)` 查当前根窗口尺寸，
  改分辨率或缩放后依然准确（不能用 `XDisplayWidth`，那是连接建立时的缓存值）。

---

## 调试

```bash
ptk-touch-gesture -d          # 前台运行，打印每次手势识别过程
ptk-touch-gesture -d --no-grab # 不独占设备（单指仍由 X 处理），只看识别
```

正常时日志形如：

```
[06:38:07] 使用触摸设备 /dev/input/event7
[06:38:07] 已启动（grab=True，raw x=(0, 639) y=(0, 479)）
[06:38:31] 指针模式：开始移动指针（双击拖动待命）
[06:38:31] 指针模式：开始拖动（左键已按下）
[06:38:32] 指针模式：长按 -> 右键（0.60s）
[06:38:36] 指针模式：单击 -> 左键
[06:38:40] 单击 -> 左键 (232,366)
```

如果启动后立刻退出，检查：

```bash
ls -l /usr/local/bin/ptk-touch-gesture   # 约 25 KB，不能是 0
pgrep -af ptk-touch-gesture              # 是否在跑
```

---

## 系统要求

- Kali Linux / Debian，**X11** 会话（xfce / mate / lxde 等均可）
- `python3`（Kali 自带）
- `libX11`、`libXtst`（桌面环境自带）
- 触摸设备名包含 `Goodix` 或 `touchscreen`，且支持 ABS_MT 多点上报

---

## 文件

```
install.sh   一键安装 / 卸载（自包含：守护程序源码内嵌其中）
README.md    本文件
LICENSE      MIT
```

只需要拷贝 `install.sh` 一个文件到目标机器即可。

---

## License

MIT
