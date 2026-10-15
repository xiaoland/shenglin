#!/usr/bin/env python3
"""编译实际 Swift/Kotlin UniFFI 接入，验证 v3/v4 握手与可选旧版本互通。"""
import json
import os
from pathlib import Path
import selectors
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "local/AndroidInterop"


def run(*args):
    subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True)


def build():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("GRADLE_USER_HOME", str(ROOT / "local/gradle-user-home"))
    if not os.environ.get("JAVA_HOME"):
        os.environ["JAVA_HOME"] = subprocess.check_output(["/usr/libexec/java_home", "-v", "17"], text=True).strip()
    run("bash", "scripts/build-rust-core.sh", "macos")
    bindings = ROOT / "local/rust-bindings/swift"
    library = ROOT / "local/rust-target/aarch64-apple-darwin/release/libshenglin_core.a"
    common = ["swiftc", "-parse-as-library", "-I", bindings,
              bindings / "ShenglinRust.swift", "Shared/Protocol.swift",
              "Shared/PairingProtocol.swift", "Shared/PeerState.swift", "Shared/WiFiPeer.swift"]
    run(*common, "scripts/test-android-interop.swift", library, "-lc++", "-o", OUTPUT / "swift-peer")
    run(*common, "Shared/WiFiPairing.swift", "Mac/BLEClient.swift",
        "scripts/test-android-wifi-peer.swift", library, "-lc++", "-o", OUTPUT / "wifi-peer")
    run("./Android/gradlew", "-p", "Android", "--no-daemon", "prepareHostInterop")
    return kotlin_command()


def kotlin_command():
    classpath = (OUTPUT / "kotlin-classpath.txt").read_text().strip()
    java_home = os.environ.get("JAVA_HOME") or subprocess.check_output(
        ["/usr/libexec/java_home", "-v", "17"], text=True).strip()
    return [str(Path(java_home) / "bin/java"),
            f"-Djna.library.path={ROOT / 'local/rust-target/aarch64-apple-darwin/release'}",
            "-cp", classpath, "local.shenglin.core.InteropMain"]


def line(process):
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        if not selector.select(10):
            raise TimeoutError("协议测试等待消息超时")
    value = process.stdout.readline()
    if not value:
        raise RuntimeError(f"协议进程提前结束：{process.poll()}")
    return json.loads(value)


def exchange(initiator_command, responder_command, initiator_platform, responder_platform, version=4):
    processes = []
    try:
        for command, role, platform in [(initiator_command, "initiator", initiator_platform),
                                         (responder_command, "responder", responder_platform)]:
            processes.append(subprocess.Popen(command + [role, platform, str(version)], stdin=subprocess.PIPE,
                                               stdout=subprocess.PIPE, bufsize=0))
        initiator, responder = processes
        for sender, recipient in [(initiator, responder), (responder, initiator),
                                  (initiator, responder), (responder, initiator)]:
            frame = line(sender)
            assert frame["v"] == version, frame
            recipient.stdin.write((json.dumps(frame, ensure_ascii=False) + "\n").encode())
            recipient.stdin.flush()
        first, second = line(initiator), line(responder)
        assert first["result"] == second["result"] == "ok"
        assert first["proof"] == second["proof"], "双方派生密钥不同"
        for field in ("stateSignature", "ackSignature", "serviceName", "wifiProof",
                      "networkMediumWifiProof", "networkMediumEthernetProof"):
            assert first[field] == second[field], f"跨语言协议字段不一致：{field}"
        assert first["peerPlatform"] == (responder_platform if version == 4 else "")
        assert second["peerPlatform"] == (initiator_platform if version == 4 else "")
        for process in processes:
            assert process.wait(timeout=10) == 0
        print(f"通过 v{version}：{initiator_platform} 发起 → {responder_platform} 响应")
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
            process.wait()


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--legacy-dir", type=Path,
                        help="迁移前保存的 interop 目录，用真实旧实现额外验证混合版本")
    args = parser.parse_args()
    kotlin = kotlin_command() if args.skip_build else build()
    swift = [str(OUTPUT / "swift-peer")]
    for platform in ("mac", "ipad"):
        exchange(kotlin, swift, "android", platform)
        exchange(swift, kotlin, platform, "android")
    exchange(kotlin, kotlin, "android", "android")
    exchange(swift, swift, "mac", "ipad", 3)
    if args.legacy_dir:
        old_swift = [str(args.legacy_dir.resolve() / "swift-peer")]
        for new, platform in [(swift, "mac"), (kotlin, "android")]:
            exchange(old_swift, new, "ipad", platform)
            exchange(new, old_swift, platform, "ipad")
        exchange(old_swift, swift, "mac", "ipad", 3)
        exchange(swift, old_swift, "mac", "ipad", 3)

        legacy = args.legacy_dir.resolve()
        if (legacy / "local/shenglin/core/InteropMain.class").exists():
            old_java = [kotlin[0], f"-Djava.library.path={legacy}", "-cp",
                        f"{legacy}:{legacy / 'json-20240303.jar'}", "local.shenglin.core.InteropMain"]
            for new, platform in [(swift, "mac"), (kotlin, "android")]:
                exchange(old_java, new, "android", platform)
                exchange(new, old_java, platform, "android")
