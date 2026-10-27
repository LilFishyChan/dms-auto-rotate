#!/usr/bin/env python3
"""nabu-autorotate — DMS 插件的通用自动旋转守护进程。

传感器后端按优先级自动探测：
    1. iio-sensor-proxy  (D-Bus net.hadess.SensorProxy)  ← 通用，x86/多数 ARM
    2. ssccli --sensor accelerometer                     ← Qualcomm SSC（nabu 走这条）
    3. /sys/bus/iio/devices/*/in_accel_*                 ← 裸 IIO 兜底

旋转用 niri IPC：`niri msg output <OUTPUT> transform <normal|90|180|270>`。
目标输出可在插件设置里指定（留空 = 自动取第一个）。

全部配置来自 DMS 的 plugin_settings.json（pluginId = nabuAutoRotate）：
    active, output, swap_xy, invert_x, invert_y, debounce_ms, dominate_ratio_x10
"""

import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time

PLUGIN_ID = "nabuAutoRotate"
DMS_SETTINGS = os.path.expanduser("~/.config/dms/plugin_settings.json")
STATE_DIR = os.path.expanduser("~/.local/state/nabu-autorotate")
LOG = os.path.join(STATE_DIR, "log")
STATE_FILE = os.path.join(STATE_DIR, "state.json")

DEFAULTS = {
    # 不能叫 active：DMS 会在插件加载时把这个键当自己的状态重置掉，
    # 重启几次自动旋转就永远是关的
    "autorotate_on": True,
    "output": "",
    "sensor_backend": "iio",    # iio | ssccli | sysfs（"auto" 仍接受，兼容旧配置）
    "swap_xy": False,
    "invert_x": False,
    "invert_y": False,
    "debounce_ms": 700,
    "dominate_ratio_x10": 16,
}

MAP = {"y_pos": "normal", "y_neg": "180", "x_pos": "270", "x_neg": "90"}

# 平放死区：X、Y 都很小时重力几乎全在 Z 轴，方向无意义。
# 没有这个门槛时平放期间传感器噪声会让 |Y| 偶尔压过 |X|，方向在两种朝向之间乱跳。
FLAT_THRESHOLD = 2.5   # m/s²

RE_XYZ = re.compile(r"X=([-\d.]+)\s+Y=([-\d.]+)\s+Z=([-\d.]+)")
G_ACCEL = 9.80665


def write_state(active, sensor_transform, applied_transform, output=""):
    """给 UI 浮层用：设备朝向 vs 屏幕朝向。自动旋转关闭时两者可能不一致。"""
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        tmp = STATE_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump({
                "active": bool(active),
                "sensor_transform": sensor_transform or "",
                "applied_transform": applied_transform or "",
                "pending": bool(sensor_transform and applied_transform
                                and sensor_transform != applied_transform),
                "output": output or "",
            }, f)
        os.replace(tmp, STATE_FILE)
    except Exception:
        pass


def log(msg):
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(LOG, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass


# ───────────────────────────── 配置 ─────────────────────────────

def _migrate_active(cfg):
    """老配置里叫 active，DMS 会重置它；读到就搬到 autorotate_on。"""
    if "active" in cfg and "autorotate_on" not in cfg:
        cfg["autorotate_on"] = bool(cfg.pop("active"))
    return cfg


def load_settings():
    raw = {}
    try:
        with open(DMS_SETTINGS) as f:
            raw = json.load(f).get(PLUGIN_ID, {})
    except Exception:
        pass
    raw = _migrate_active(dict(raw))
    s = dict(DEFAULTS)
    s.update({k: raw[k] for k in DEFAULTS if k in raw})
    return s


def settings_mtime():
    try:
        return os.path.getmtime(DMS_SETTINGS)
    except Exception:
        return 0.0


# ──────────────────────────── niri IPC ───────────────────────────

def niri_socket():
    try:
        out = subprocess.run(
            ["systemctl", "--user", "show-environment"],
            capture_output=True, text=True, timeout=5,
        ).stdout
        for line in out.splitlines():
            if line.startswith("NIRI_SOCKET="):
                return line.split("=", 1)[1].strip()
    except Exception:
        pass
    return None


def niri_outputs(sock):
    try:
        env = os.environ.copy()
        env["NIRI_SOCKET"] = sock
        out = subprocess.run(
            ["niri", "msg", "--json", "outputs"],
            capture_output=True, text=True, env=env, timeout=5,
        ).stdout
        return json.loads(out)
    except Exception:
        return {}


def resolve_output(sock, preferred):
    """设置里指定了就用它，否则取第一个。

    "auto"（以及历史配置里残留的空串）表示「用第一个输出」，不算错误，
    不报警 —— DMS 的 SelectionSetting 曾经把中文标签写进配置，迁移后统一成
    auto 这个哨兵值。
    """
    outs = niri_outputs(sock)
    if not outs:
        return None
    if preferred in ("", "auto"):
        return next(iter(outs))
    if preferred in outs:
        return preferred
    log(f"指定的输出 {preferred} 不存在，改用第一个")
    return next(iter(outs))


def current_transform(sock, output):
    d = niri_outputs(sock).get(output, {})
    return d.get("logical", {}).get("transform", "").lower()


def apply_transform(transform, sock, output):
    env = os.environ.copy()
    env["NIRI_SOCKET"] = sock
    try:
        r = subprocess.run(
            ["niri", "msg", "output", output, "transform", transform],
            capture_output=True, text=True, env=env, timeout=5,
        )
        if r.returncode == 0:
            log(f"旋转 {output} → {transform}")
            return True
        log(f"旋转失败 {transform}: {(r.stderr or r.stdout).strip()}")
    except Exception as e:
        log(f"旋转异常 {transform}: {e}")
    return False


# ───────────────────────── 传感器后端 ─────────────────────────

def _gdbus(*args):
    r = subprocess.run(
        ["gdbus", "call", "--system",
         "--dest", "net.hadess.SensorProxy",
         "--object-path", "/net/hadess/SensorProxy", *args],
        capture_output=True, text=True, timeout=3,
    )
    return r.stdout.strip()


def _gdbus_get(prop):
    return _gdbus("--method", "org.freedesktop.DBus.Properties.Get",
                  "net.hadess.SensorProxy", prop)


IIO_ORIENT_TO_XY = {
    # iio-sensor-proxy 的 AccelerometerOrientation → 伪重力向量
    "normal":     (0.0,  G_ACCEL),   # 竖立
    "bottom-up":  (0.0, -G_ACCEL),   # 倒立
    "left-up":    (-G_ACCEL, 0.0),   # 左横
    "right-up":   (G_ACCEL, 0.0),    # 右横
}


def iio_probe():
    """iio-sensor-proxy 是否真能给出方向（nabu 上是 undefined，要排除）。"""
    if not shutil.which("gdbus"):
        return False
    try:
        if "true" not in _gdbus_get("HasAccelerometer"):
            return False
        _gdbus("--method", "net.hadess.SensorProxy.ClaimAccelerometer")
        seen = []
        for _ in range(3):
            o = _gdbus_get("AccelerometerOrientation")
            seen.append(o)
            if "undefined" not in o:
                return True
            time.sleep(0.4)
        log(f"iio-sensor-proxy 方向恒为 undefined（{seen}），跳过")
        return False
    except Exception as e:
        log(f"iio-sensor-proxy 探测失败: {e}")
        return False


def iio_stream():
    while True:
        try:
            o = _gdbus_get("AccelerometerOrientation")
        except Exception:
            time.sleep(1)
            continue
        key = next((k for k in IIO_ORIENT_TO_XY if f"'{k}'" in o), None)
        if key:
            yield IIO_ORIENT_TO_XY[key]
        time.sleep(0.5)


def ssccli_stream():
    """ssccli 没有流式参数，只有 --timeout（运行 N 秒后退出）。

    给一个很大的 timeout 看起来像"长流"，实际会让它常驻并且占满一个 CPU 核
    （实测 --timeout 86400 稳定吃 99.6%），在电池设备上是灾难。所以按短周期
    反复重开：每次 2 秒，读完接着起下一个，开销远小于常驻空转。

    外面必须再套一层 `timeout -k`：ssccli 自己的 --timeout 只是在 SLPI 正常
    响应时计时，一旦 SLPI 卡住它既不输出也不退出，`for line in proc.stdout`
    就会永久阻塞，进程挂在那里 99% CPU 狂刷 SLPI。实测这个卡死进程会把 SLPI
    的 sensor_process 初始化压到看门狗超时（每 40 秒崩一次），SLPI 崩溃期间
    I2C 总线被干扰，连累 LN8000 充电芯片的状态寄存器读错 —— 表现为直充突然
    disable、ADC 读到恒定假值。外部 timeout 是唯一能兜住这种情况的手段。
    """
    while True:
        proc = subprocess.Popen(
            ["timeout", "-k", "2", "6",
             "ssccli", "--sensor", "accelerometer", "--timeout", "2"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1,
        )
        try:
            for line in proc.stdout:
                m = RE_XYZ.search(line)
                if m:
                    yield float(m.group(1)), float(m.group(2))
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except Exception:
                proc.kill()


def sysfs_accel_device():
    for d in sorted(glob.glob("/sys/bus/iio/devices/iio:device*")):
        try:
            name = open(os.path.join(d, "name")).read().strip().lower()
        except Exception:
            continue
        if "accel" in name and os.path.exists(os.path.join(d, "in_accel_x_raw")):
            return d
    return None


def sysfs_stream(path):
    def raw(axis):
        return int(open(os.path.join(path, f"in_accel_{axis}_raw")).read())

    try:
        scale = float(open(os.path.join(path, "in_accel_scale")).read())
    except Exception:
        scale = 1.0
    while True:
        try:
            yield raw("x") * scale, raw("y") * scale
        except Exception:
            pass
        time.sleep(0.5)


def pick_backend(preferred="auto"):
    """preferred: auto | iio | ssccli | sysfs

    iio 只有在方向真的可信时才能用 —— 固件 mount matrix 全 0 的设备上它会
    返回非 undefined 但完全错误的方向（实测 nabu 上竖放报 right-up）。
    """
    # auto：先试 ssccli。这类平板（骁龙 SSC）上 iio 的固件 mount matrix 常常
    # 全是 0，方向不可信；而且 claim 可能被 polkit 拒，白白占一次传感器。
    if preferred in ("ssccli", "auto") and shutil.which("ssccli"):
        return "ssccli (Qualcomm SSC)", ssccli_stream
    if preferred in ("iio", "auto") and iio_probe():
        return "iio-sensor-proxy", iio_stream
    if preferred == "iio":
        log("指定的 iio 后端不可用，回退自动探测")
    if preferred == "ssccli":
        log("指定的 ssccli 不可用，回退自动探测")
    dev = sysfs_accel_device()
    if dev:
        return f"sysfs ({dev})", lambda: sysfs_stream(dev)
    return None, None


# ──────────────────────────── 判定 ────────────────────────────

def decide(x, y, cfg):
    if cfg["swap_xy"]:
        x, y = y, x
    if cfg["invert_x"]:
        x = -x
    if cfg["invert_y"]:
        y = -y
    # 平放（重力在 Z 轴）时不做方向判定，避免噪声导致来回跳
    if abs(x) < FLAT_THRESHOLD and abs(y) < FLAT_THRESHOLD:
        return None

    ratio = cfg["dominate_ratio_x10"] / 10.0
    if abs(x) >= abs(y) * ratio:
        return MAP["x_pos"] if x > 0 else MAP["x_neg"]
    if abs(y) >= abs(x) * ratio:
        return MAP["y_pos"] if y > 0 else MAP["y_neg"]
    return None


# ───────────────────────────── 主循环 ─────────────────────────────

def main():
    sock = niri_socket()
    if not sock:
        log("拿不到 NIRI_SOCKET，退出")
        return 1

    cfg = load_settings()
    output = resolve_output(sock, cfg["output"])
    if not output:
        log("找不到任何 niri 输出，退出")
        return 1

    backend_name, backend = pick_backend(cfg.get("sensor_backend", "iio"))
    if not backend:
        log("没有可用的传感器后端（iio-sensor-proxy / ssccli / sysfs 都不可用），退出")
        return 1

    last_mtime = settings_mtime()
    current = current_transform(sock, output)
    log(f"启动: 输出={output} 后端={backend_name} 初始={current} 配置={cfg}")

    candidate = None
    candidate_since = 0.0
    last_active = cfg["autorotate_on"]
    last_reported = None
    first_frame = True

    gen = backend()
    while True:
        try:
            x, y = next(gen)
        except StopIteration:
            break
        except Exception as e:
            log(f"传感器流异常退出: {e}")
            break

        mt = settings_mtime()
        if mt != last_mtime:
            last_mtime = mt
            new = load_settings()
            if new["output"] != cfg["output"]:
                new_out = resolve_output(sock, new["output"])
                if new_out and new_out != output:
                    log(f"输出切换: {output} → {new_out}")
                    output = new_out
                    current = current_transform(sock, output)
            if new["sensor_backend"] != cfg["sensor_backend"]:
                # 换后端必须重建传感器流，仅改 cfg 没用
                try:
                    gen.close()
                except Exception:
                    pass
                new_name, new_backend = pick_backend(new["sensor_backend"])
                if new_backend:
                    backend_name, backend = new_name, new_backend
                    gen = backend()
                    first_frame = True
                    candidate = None
                    log(f"后端已切换: {backend_name}")
                else:
                    log("新后端不可用，保持原后端")
            if new != cfg:
                log("配置已更新: "
                    f"{ {k: new[k] for k in ('autorotate_on','output','sensor_backend','swap_xy','invert_x','invert_y','debounce_ms','dominate_ratio_x10')} }")
            cfg = new

        now = time.time()
        on = bool(cfg["autorotate_on"])
        changed = (on != last_active)
        if changed:
            last_active = on
            log("自动旋转已启用" if on else "自动旋转已关闭，保持当前方向")
            candidate = None

        target = decide(x, y, cfg)

        # 状态上报：active 关着时也要报，浮层要知道「设备转了但屏幕没转」
        if target != last_reported or changed:
            last_reported = target
            write_state(on, target, current_transform(sock, output), output)

        if not on:
            first_frame = False
            continue

        if first_frame or changed:
            first_frame = False
            if target is not None and target != current:
                if apply_transform(target, sock, output):
                    current = target
            elif target is not None:
                log(f"启用即同步：当前已是 {target}")
            candidate = None
            continue

        if target is None or target == current:
            candidate = None
            continue
        if target != candidate:
            candidate = target
            candidate_since = now
            continue
        if now - candidate_since >= cfg["debounce_ms"] / 1000.0:
            if apply_transform(target, sock, output):
                current = target
            candidate = None

    return 0


if __name__ == "__main__":
    sys.exit(main())
