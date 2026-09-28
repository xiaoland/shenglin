#!/usr/bin/env python3
"""用两个不同 bundle ID 的 App 和专用设备检验已安装驱动；先退出 Nearby GUI。"""
import json
import os
from pathlib import Path
import plistlib
import selectors
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "local" / "HALIsolationTests"


def run(*args):
    subprocess.run([str(a) for a in args], check=True)


def request(process, command):
    process.stdin.write(command + "\n")
    process.stdin.flush()
    return line(process)


def line(process):
    with selectors.DefaultSelector() as poll:
        poll.register(process.stdout, selectors.EVENT_READ)
        if not poll.select(5):
            raise RuntimeError(f"测试 App {process.pid} 五秒内未响应")
    result = process.stdout.readline().strip()
    if not result:
        raise RuntimeError(f"测试 App {process.pid} 提前结束")
    return result


def stop(process):
    if process and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    binary = BUILD / "Probe"
    run("xcrun", "clang++", "-std=c++17", "-O2", ROOT / "experiments/VirtualMicrophoneProbe.cpp",
        "-framework", "CoreAudio", "-framework", "CoreFoundation", "-framework", "AudioUnit", "-o", binary)
    identity = os.environ.get("NEARBY_AUDIO_SIGN_IDENTITY", "-")
    executables = []
    for name in ("A", "B"):
        app = BUILD / f"Reader{name}.app"
        executable = app / "Contents/MacOS" / f"Reader{name}"
        executable.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(binary, executable)
        with (app / "Contents/Info.plist").open("wb") as file:
            plistlib.dump({"CFBundleExecutable": executable.name,
                          "CFBundleIdentifier": f"local.nearbyaudio.haltest.reader{name}",
                          "CFBundleName": f"Nearby HAL Test {name}", "CFBundlePackageType": "APPL",
                          "CFBundleVersion": "1", "LSUIElement": True,
                          "NSMicrophoneUsageDescription": "读取 Nearby 虚拟设备的合成样本，检验逐应用静音。"}, file)
        run("codesign", "--force", "--options", "runtime", "--sign", identity, app)
        run("codesign", "--verify", "--strict", app)
        executables.append(executable)

    readers, feeds, stages, failures = [], [], {}, []
    original = subprocess.check_output([str(binary), "configuration"])
    original_devices = plistlib.loads(original) if original else []
    configs = [{"bundle": f"local.nearbyaudio.haltest.reader{name}", "name": f"HAL Test {name}"} for name in ("A", "B")]
    if any(x["bundle"] in {c["bundle"] for c in configs} for x in original_devices):
        raise RuntimeError("测试设备已存在；请先移除旧测试配置")
    uids = ["local.nearbyaudio.virtual-microphone." + x["bundle"] for x in configs]
    original_file = BUILD / "original.plist"
    original_file.write_bytes(plistlib.dumps(original_devices))
    config_file = BUILD / "devices.plist"
    config_file.write_bytes(plistlib.dumps(original_devices + configs))
    device_ids, error = [], None

    def mute(index, value):
        run(binary, "mute", uids[index], int(value))

    def measure(name, expected):
        # 给控制命令和驱动缓冲留出时间；随后统计独立的半秒窗口。
        time.sleep(0.4)
        for p in readers:
            request(p, "stats")
        time.sleep(0.5)
        stats = [list(map(int, request(p, "stats").split())) for p in readers]
        stages[name] = stats
        for app, (count, hits, errors, zero_frames, max_zero_run), audible in zip(("A", "B"), stats, expected):
            valid = count > 10000 and errors == 0 and (
                hits > count * 0.99 and zero_frames < count * 0.005 and max_zero_run < 480
                if audible else hits == 0)
            if not valid:
                failures.append(f"{name}/{app}: 期望{'连续样本' if audible else '静音'}，实际 {count=} {hits=} {errors=} {zero_frames=} {max_zero_run=}")
        print(name, json.dumps(stats), flush=True)

    try:
        run(binary, "configure", config_file)
        time.sleep(1)
        for index in range(2):
            mute(index, False)
        for executable, uid in zip(executables, uids):
            p = subprocess.Popen([str(executable), "read", uid], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, text=True, bufsize=1)
            readers.append(p)
            ready = line(p).split()
            if len(ready) != 3 or ready[0] != "ready" or int(ready[1]) != p.pid:
                raise RuntimeError(f"测试 App 握手异常：{ready}")
            device_ids.append(int(ready[2]))
        if len(set(device_ids)) != 2:
            raise RuntimeError("两个测试 App 没有使用独立设备")
        feeds = [subprocess.Popen([str(binary), "feed", uid]) for uid in uids]
        measure("baseline", (True, True))
        if failures:
            raise RuntimeError("基础供音失败，不能继续判断逐应用静音")
        request(readers[0], "self 1")
        measure("system-self-mute-A", (False, True))
        request(readers[0], "self 0")
        measure("system-self-unmute-A", (True, True))
        if failures:
            raise RuntimeError("系统静音正向对照失败，测试条件不成立")
        mute(0, True)
        measure("driver-mute-A", (False, True))
        mute(0, False)
        measure("driver-unmute-A", (True, True))
        mute(1, True)
        measure("driver-mute-B", (True, False))
        mute(1, False)
        measure("driver-unmute-B", (True, True))
        for feed in feeds: stop(feed)
        measure("source-stopped", (False, False))
    except Exception as exc:
        error = str(exc)
        raise
    finally:
        for feed in feeds: stop(feed)
        for p in readers: stop(p)
        restored = subprocess.run([str(binary), "configure", str(original_file)], check=False).returncode == 0
        if not restored: failures.append("无法恢复原始设备配置")
        (BUILD / "results.json").write_text(json.dumps({"stages": stages, "failures": failures,
                                                      "error": error, "deviceIDs": device_ids},
                                                      ensure_ascii=False, indent=2) + "\n")
    for failure in failures:
        print(failure)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
